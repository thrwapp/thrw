import {
  DeviceRegistry,
  PriorityEngine,
  systemScheduler,
  type EventPayload,
  type RelayMqttClient,
  type Scheduler,
} from "@thrw/relay-core";
import { PRIORITY_ORDER } from "@thrw/protocol";
import { COMMAND_OUTCOME_KIND, RESOURCE_AUDIO } from "@thrw/protocol";
import type {
  CommandFailureReason,
  CommandOutcome,
  CommandOutcomePayload,
  EventKind,
  NodeManifest,
  ResourceType,
} from "@thrw/protocol";

// #118: the actual long-running decision service - subscribes to every
// registered node's events per account, drives one PriorityEngine per
// account, and publishes CLAIM/RELEASE back to whichever node(s) the
// resulting holder change concerns. Not new arbitration logic (#113/#114
// already proved PriorityEngine/RelayMqttClient work together over a real
// broker) - this is packaging that logic as a live subscriber.

const REGISTRATION_KIND = "register";
const EVENT_END_KIND = "event_end";

/**
 * One structured line per thing the relay decided or failed to do (#207).
 *
 * Before this, the only `console.*` calls in this file were four error
 * paths and a drift warning - so the log recorded what went *wrong* and
 * never what happened. A handoff that worked left no trace at all, which
 * makes "why did it switch then?" and "did it switch at all?"
 * unanswerable after the fact, and those are exactly the questions a
 * multi-day dogfood run produces.
 *
 * JSON rather than prose because these lines are meant to be filtered
 * (`docker logs relay-service | jq 'select(.event == "claim")'`) and,
 * later, ingested - ADR 0019's switch-success-rate metric and ADR 0018's
 * reconciliation-mismatch metric both want this data, and a prose line
 * would have to be re-parsed to get it. This is deliberately not a
 * logging library: one function, no dependency, no configuration.
 *
 * `ts` is included rather than left to the log driver, so a line keeps
 * its timestamp once it is copied out of Docker into an archive file.
 */
function logEvent(event: string, fields: Record<string, unknown>): void {
  console.log(JSON.stringify({ ts: new Date().toISOString(), event, ...fields }));
}

// Wire shapes riding the (frozen) events topic alongside EventPayload,
// distinguished by their `kind` discriminator - see
// AndroidNode.kt/Payloads.kt's own kdoc (docs/handoffs/67.md, 68.md) and
// packages/relay-core/test/handoff-integration.test.ts's own local
// EventEndPayload for precedent. Not exported from @thrw/relay-core or
// @thrw/protocol (neither package parses these discriminators yet), so -
// same as that test - these are defined locally rather than smuggled into
// a package this issue's own acceptance criterion 6 says not to change.
interface RegistrationPayload {
  kind: typeof REGISTRATION_KIND;
  manifest: NodeManifest;
  // The node's currently-active triggers (#178). Every registration
  // carries them, so the relay's view converges on the node's own rather
  // than being inferred from a stream of edges it may have missed.
  // Optional on the wire: an adapter that predates this sends none, which
  // reads as "nothing active" - identical to #173's fresh-process case.
  activeEvents?: EventKind[];
  /**
   * The node's observed audio route per resource type (#191), keyed by
   * ADR 0015's vocabulary. A resource is absent when the node cannot
   * determine it, or while a claim/release is still settling - absent
   * means "no information", not "no".
   */
  observedRoutes?: Record<string, boolean>;
}

/** ADR 0015's resource type for the headset audio connection. */
/**
 * Every resource type this process manages (ADR 0015). Engines are
 * created eagerly for all of them, so `engineFor` is deterministic in
 * tests rather than depending on whether an event has arrived yet.
 */
const ALL_RESOURCE_TYPES: readonly ResourceType[] = ["audio", "hid"];

/**
 * A disagreement between what the relay records as the holder and what a
 * node observes about its own audio route (#191).
 */
export interface RouteDrift {
  readonly account: string;
  readonly node: string;
  /** What the node says about its own route. */
  readonly nodeHoldsRoute: boolean;
  /** Who the relay believed held it at the time. */
  readonly believedHolder: string | null;
}

/**
 * A registration the relay acted on (#245).
 *
 * The relay's four original log events are all *outputs* - what it
 * decided. None of its *inputs* were recorded, and over one day of live
 * debugging that gap blocked diagnosis four separate times: "why did the
 * holder change", "why did it *not* change", "which version is that node
 * running" and "was that node reaped" were all unanswerable from the
 * logs, and each produced a wrong hypothesis before the real cause was
 * found some other way.
 *
 * This is the highest-value of the three: it records what each node is
 * claiming, once per registration, per node.
 *
 * **`displayName` is deliberately omitted.** It is user-chosen and
 * routinely personal ("Tom's MacBook Air"), nothing here needs it, and
 * #207's open question about `{account}` already being a user identifier
 * says to add no more identifying content than the account id every
 * existing line already carries.
 */
export interface RegistrationObserved {
  readonly account: string;
  readonly node: string;
  readonly resource: ResourceType;
  readonly platform: string;
  /** From `NodeManifest` - answers "is the fix on the device yet?" (#242). */
  readonly adapterVersion: string;
  /** What the node says it currently has active. */
  readonly activeEvents: readonly EventKind[];
  /** What the node says about its own routes; `{}` means "no information". */
  readonly observedRoutes: Record<string, boolean>;
  readonly holderBefore: string | null;
  readonly holderAfter: string | null;
}

/** A trigger start or end the relay acted on (#245). */
export interface NodeEventObserved {
  readonly account: string;
  readonly node: string;
  readonly resource: ResourceType;
  readonly kind: "event" | "event_end";
  readonly type: EventKind;
  readonly holderBefore: string | null;
  readonly holderAfter: string | null;
}

/**
 * A node dropped by the heartbeat sweep (#245).
 *
 * `sweepHeartbeats` previously logged nothing at all, which is why
 * #236's nine-hour holder oscillation was invisible: every reap surfaced
 * as a bare `holder_change` with no recorded cause, and reconstructing
 * it afterwards took a day of log archaeology.
 */
export interface NodeReaped {
  readonly account: string;
  readonly node: string;
  /** How long since its last heartbeat, at the moment it was dropped. */
  readonly silentForMs: number;
}

/**
 * How a claim or release a node was sent actually ended (ADR 0019, #206).
 *
 * Before this, a command was fire-and-forget: the relay published it and
 * never learned whether the switch happened. "Did that work?" was
 * unanswerable except by looking at the headset, and switch success rate
 * — the number that says whether thrw is reliable — could not be
 * measured at all.
 *
 * Reported for **every** command, not only failures: a rate needs its
 * denominator.
 */
export interface CommandOutcomeReported {
  readonly account: string;
  readonly node: string;
  readonly resource: ResourceType;
  /**
   * Identifies which command this answers - see `CommandOutcomePayload`.
   *
   * Optional for the same reason the payload's are: a command carrying
   * neither is still acted on by both adapters, and its outcome has to
   * stay reportable rather than being dropped as malformed.
   */
  readonly epoch?: string;
  readonly seq?: number;
  readonly outcome: CommandOutcome;
  readonly reason?: CommandFailureReason;
  readonly durationMs: number;
}

interface EventEndPayload {
  kind: typeof EVENT_END_KIND;
  type: EventKind;
}

function isRegistrationPayload(payload: unknown): payload is RegistrationPayload {
  return (
    typeof payload === "object" &&
    payload !== null &&
    (payload as { kind?: unknown }).kind === REGISTRATION_KIND
  );
}

// Defensive: this comes off the wire, so anything that isn't a known
// EventKind is dropped rather than trusted into the engine.
function activeEventsFrom(payload: RegistrationPayload): EventKind[] {
  const raw: unknown = payload.activeEvents;
  if (!Array.isArray(raw)) return [];
  return raw.filter((kind): kind is EventKind =>
    typeof kind === "string" && (PRIORITY_ORDER as readonly string[]).includes(kind),
  );
}

// Defensive, like activeEventsFrom: this comes off the wire.
function observedAudioRoute(payload: RegistrationPayload): boolean | undefined {
  const routes: unknown = payload.observedRoutes;
  if (typeof routes !== "object" || routes === null) return undefined;
  const value: unknown = (routes as Record<string, unknown>)[RESOURCE_AUDIO];
  return typeof value === "boolean" ? value : undefined;
}

function isEventEndPayload(payload: unknown): payload is EventEndPayload {
  return (
    typeof payload === "object" &&
    payload !== null &&
    (payload as { kind?: unknown }).kind === EVENT_END_KIND
  );
}

/**
 * ADR 0019 / #206. Validated field by field rather than trusted on the
 * `kind` alone: this is the one payload the relay treats as *evidence
 * about reliability*, and a malformed one silently skewing the success
 * rate is worse than no data. An outcome that fails this check falls
 * through to the unrecognized-payload path and is dropped.
 */
function isCommandOutcomePayload(payload: unknown): payload is CommandOutcomePayload {
  if (typeof payload !== "object" || payload === null) return false;
  const p = payload as Record<string, unknown>;
  if (p.kind !== COMMAND_OUTCOME_KIND) return false;
  // `epoch`/`seq` are optional, matching `CommandPayload`'s own and what
  // both adapters actually send. Requiring them - as this originally did
  // - would have silently rejected the outcome for any *unsequenced*
  // command, and the adapters deliberately still act on those (ADR 0018
  // point 1 shipped relay-first, so builds exist that ran against a
  // relay stamping nothing). A wrong type is still malformed; an absent
  // one is not.
  if (p.epoch !== undefined && typeof p.epoch !== "string") return false;
  if (p.seq !== undefined && typeof p.seq !== "number") return false;
  if (typeof p.durationMs !== "number") return false;
  if (p.outcome !== "succeeded" && p.outcome !== "failed" && p.outcome !== "timed_out") return false;
  // A reason is meaningful only on a failure, and a failure without one
  // is unaggregatable - which is the entire purpose of the field.
  if (p.outcome === "failed" && typeof p.reason !== "string") return false;
  return true;
}

function isEventPayload(payload: unknown): payload is EventPayload {
  return (
    typeof payload === "object" &&
    payload !== null &&
    !("kind" in (payload as object)) &&
    typeof (payload as { type?: unknown }).type === "string" &&
    typeof (payload as { priority?: unknown }).priority === "number"
  );
}

// 3x architecture.md's "~30s" heartbeat interval - a couple of missed
// beats is normal jitter, three in a row is "stale". A judgment call
// (#118 acceptance criterion 2 explicitly asks for one, since the wire
// protocol has no explicit "goodbye" message) - not derived from any
// measurement, just a round multiple of the documented interval.
//
// This used to mean "gone", and no longer does (#263). Crossing it stops
// a node counting as live; what happens to the signals it holds is
// decided by DEFAULT_NODE_DEPARTURE_TIMEOUT_MS below. The 3:1 ratio both
// adapters' heartbeat publishers document as a contract is unchanged -
// this is still that number, still 3x 30s.
const DEFAULT_HEARTBEAT_TIMEOUT_MS = 90_000;

// How often each account's registry is swept for timed-out nodes. Well
// under the timeout itself so a departed node isn't left registered much
// longer than DEFAULT_HEARTBEAT_TIMEOUT_MS actually implies.
const DEFAULT_HEARTBEAT_SWEEP_INTERVAL_MS = 15_000;

// How long a node must stay silent before the relay treats it as *gone*
// rather than merely quiet, and drops the signals it had (#263).
//
// The 90s above was chosen against "an assumption of always-awake nodes
// that the reference hardware does not meet". Neither reference device
// meets it: a sleeping Mac cannot send anything at all, and a dozing
// Pixel has its timers deferred by the OS. Measured over 9h49m of
// production relay log (2026-09-23 10:22Z-20:11Z, archive
// relay-service-20260923T203636Z.log):
//
//   164 node_reaped, 223 registration, 14 holder_change
//   registration gaps: Pixel p50 160s / max 2263s against a 120s timer,
//                      Mac   p50 438s / max 1126s
//   silence episodes:  p50 128s, p90 940s
//
// So the old rule fired 164 times in ten hours, and a p50 of 128s means
// it fired hardest on the *shortest* silences - the ones least likely to
// mean anything. Not one of those 164 reaps dropped a signal: all 164 hit
// a node with nothing active, where `PriorityEngine.forgetNode` ->
// `dropSignals` returns early and the reap is a no-op. The destructive
// case - a node reaped while it still has an active trigger - did not
// occur once.
//
// 300s is taken from the same measurement rather than picked as a round
// number: replaying those silence episodes, a 300s threshold would have
// reaped 34 times instead of 164, and it is the knee of the curve (180s ->
// 61, 300s -> 34, 420s -> 26, 600s -> 23). Long enough that ordinary doze
// and Mac sleep pass under it, short enough that a node which is genuinely
// gone does not hold a signal for long.
//
// Deliberately NOT a change to the 30s/90s pair. Both adapters'
// heartbeat publishers document that pair as a contract that must stay
// 3:1 ("changing one without the other silently changes how long a dead
// node keeps its claim - or starts reaping live ones"), and #236 and #251
// are both recent, expensive lessons in touching this machinery. 90s still
// means "stale" exactly as before; this is a second, later threshold for
// the one action that cannot be undone.
const DEFAULT_NODE_DEPARTURE_TIMEOUT_MS = 300_000;

export interface RelayServiceOptions {
  /** An already-connected client - this class never calls `RelayMqttClient.connect` itself. */
  client: RelayMqttClient;
  /**
   * Which accounts this process manages. Static, not discovered - see
   * docs/handoffs/118.md's "Known gaps" for why (no accounts/licensing
   * service exists yet to discover them from).
   */
  accounts: readonly string[];
  /** Injectable clock, so heartbeat-timeout tests don't wait on wall time. */
  now?: () => number;
  /**
   * Called when a node's observed route disagrees with the recorded
   * holder (#191). Defaults to logging.
   *
   * ADR 0018's consequences are explicit that a mismatch is a leading
   * indicator of a bug rather than routine noise, so it is surfaced
   * rather than silently corrected. Injectable so tests can assert on it
   * without scraping stdout.
   */
  onRouteDrift?: (drift: RouteDrift) => void;
  /**
   * Called for every registration the relay acts on (#245). Defaults to
   * logging. Same injectable-sink shape as `onRouteDrift` above, for the
   * same reason: tests assert on a structured object rather than
   * scraping stdout.
   */
  onRegistration?: (registration: RegistrationObserved) => void;
  /** Called for every trigger start/end the relay acts on (#245). */
  onNodeEvent?: (event: NodeEventObserved) => void;
  /** Called for every node the heartbeat sweep drops (#245). */
  onNodeReaped?: (reaped: NodeReaped) => void;
  /**
   * Called for every command outcome a node reports (ADR 0019, #206).
   * Defaults to logging.
   *
   * This is the seam a real telemetry sink plugs into without touching
   * arbitration logic — `services/telemetry` is still a placeholder, and
   * ADR 0019 explicitly sanctions landing the reporting first and
   * emitting into the existing logging path until it is real.
   */
  onCommandOutcome?: (outcome: CommandOutcomeReported) => void;
  /**
   * Injectable scheduler - used both for each account's `PriorityEngine`
   * (its own auto-return timer) and for the heartbeat sweep, so a test can
   * control both deterministically with one fake, the same pattern
   * `packages/relay-core/test/handoff-integration.test.ts` already uses
   * for `PriorityEngine` alone.
   */
  scheduler?: Scheduler;
  heartbeatTimeoutMs?: number;
  heartbeatSweepIntervalMs?: number;
  /**
   * How long a node stays silent before its signals are dropped (#263).
   * Defaults to `DEFAULT_NODE_DEPARTURE_TIMEOUT_MS`. Must be >=
   * `heartbeatTimeoutMs`; a smaller value is clamped up to it, since
   * "gone" cannot precede "stale".
   */
  nodeDepartureTimeoutMs?: number;
}

/**
 * Per-account state (#171).
 *
 * The registry and liveness live here rather than per-resource because
 * they are facts about **nodes**: a manifest describes one device, and a
 * heartbeat says its process is running. Arbitration is what became
 * per-resource - see [ResourceState].
 */
interface AccountState {
  readonly account: string;
  readonly registry: DeviceRegistry;
  /** One per resource type, created eagerly so tests are deterministic. */
  readonly resources: Map<ResourceType, ResourceState>;
  readonly lastHeartbeatAt: Map<string, number>;
  readonly heartbeatSubscribed: Set<string>;
  sweepHandle: unknown;
}

/**
 * Arbitration for one resource type within one account (ADR 0015).
 *
 * Priority rules are resource-type-specific - "a call is ringing" has no
 * sensible mapping onto "should the keyboard switch" - so each resource
 * gets its own engine and its own notion of who holds it.
 */
interface ResourceState {
  readonly account: string;
  readonly resource: ResourceType;
  readonly engine: PriorityEngine;
  lastHolder: string | null;
  /**
   * What this process has published on the retained state topic (#222).
   *
   * Deliberately three-valued, and `undefined` is the important one: it
   * means *this process* has published nothing yet, which is not the
   * same as having published "nobody holds it". A retained message
   * outlives the process that wrote it, so after a relay restart the
   * broker is still serving the previous process's answer while this
   * one believes nothing - and `lastHolder` being `null` on both sides
   * would make that look like agreement.
   *
   * Separate from `lastHolder` rather than derived from it because they
   * answer different questions: `lastHolder` is what this relay
   * believes, `publishedHolder` is what the broker is currently telling
   * everyone. They diverge for exactly as long as a publish is in
   * flight, and across a restart.
   */
  publishedHolder: string | null | undefined;
}

/**
 * Per-account (acceptance criterion 3 - never global) wiring of
 * `RelayMqttClient`, `DeviceRegistry` and `PriorityEngine` into a live
 * subscriber. See docs/handoffs/118.md for the full design writeup,
 * including the two judgment calls (heartbeat-based "gone" detection, and
 * publishing both RELEASE-then-CLAIM on a holder change rather than just
 * one) and what's explicitly left as a known gap.
 */
export class RelayService {
  private readonly client: RelayMqttClient;
  private readonly accounts: readonly string[];
  private readonly now: () => number;
  private readonly onRouteDrift: (drift: RouteDrift) => void;
  private readonly onRegistration: (registration: RegistrationObserved) => void;
  private readonly onNodeEvent: (event: NodeEventObserved) => void;
  private readonly onNodeReaped: (reaped: NodeReaped) => void;
  private readonly onCommandOutcome: (outcome: CommandOutcomeReported) => void;
  private readonly scheduler: Scheduler;
  private readonly heartbeatTimeoutMs: number;
  private readonly heartbeatSweepIntervalMs: number;
  private readonly nodeDepartureTimeoutMs: number;
  private readonly states = new Map<string, AccountState>();

  constructor(options: RelayServiceOptions) {
    this.client = options.client;
    this.accounts = options.accounts;
    this.now = options.now ?? (() => Date.now());
    this.onRouteDrift =
      options.onRouteDrift ??
      ((drift) => {
        // ADR 0018's consequences: a mismatch is a leading indicator of a
        // bug, not routine noise. Structured so a nonzero steady-state
        // rate is countable rather than something you notice by eye.
        logEvent("route_drift", {
          account: drift.account,
          node: drift.node,
          nodeHoldsRoute: drift.nodeHoldsRoute,
          believedHolder: drift.believedHolder,
        });
      });
    // #245. One line per registration: at two nodes on the 120s cadence
    // that is ~1/minute, well inside the 20m x 5 json-file rotation
    // scripts/relay-redeploy.sh sets.
    this.onRegistration =
      options.onRegistration ??
      ((registration) => {
        logEvent("registration", {
          account: registration.account,
          node: registration.node,
          resource: registration.resource,
          platform: registration.platform,
          adapterVersion: registration.adapterVersion,
          activeEvents: registration.activeEvents,
          observedRoutes: registration.observedRoutes,
          holderBefore: registration.holderBefore,
          holderAfter: registration.holderAfter,
        });
      });
    this.onNodeEvent =
      options.onNodeEvent ??
      ((event) => {
        logEvent("node_event", {
          account: event.account,
          node: event.node,
          resource: event.resource,
          kind: event.kind,
          type: event.type,
          holderBefore: event.holderBefore,
          holderAfter: event.holderAfter,
        });
      });
    this.onNodeReaped =
      options.onNodeReaped ??
      ((reaped) => {
        logEvent("node_reaped", {
          account: reaped.account,
          node: reaped.node,
          silentForMs: reaped.silentForMs,
        });
      });
    this.onCommandOutcome =
      options.onCommandOutcome ??
      ((outcome) => {
        logEvent("command_outcome", {
          account: outcome.account,
          node: outcome.node,
          resource: outcome.resource,
          epoch: outcome.epoch,
          seq: outcome.seq,
          outcome: outcome.outcome,
          reason: outcome.reason,
          durationMs: outcome.durationMs,
        });
      });
    this.scheduler = options.scheduler ?? systemScheduler;
    this.heartbeatTimeoutMs = options.heartbeatTimeoutMs ?? DEFAULT_HEARTBEAT_TIMEOUT_MS;
    this.heartbeatSweepIntervalMs = options.heartbeatSweepIntervalMs ?? DEFAULT_HEARTBEAT_SWEEP_INTERVAL_MS;
    // Clamped rather than validated: a departure threshold below the
    // stale one would mean a node is declared gone before it is declared
    // quiet, which no caller can sensibly want, and throwing here would
    // take down a relay over a config typo.
    this.nodeDepartureTimeoutMs = Math.max(
      options.nodeDepartureTimeoutMs ?? DEFAULT_NODE_DEPARTURE_TIMEOUT_MS,
      this.heartbeatTimeoutMs,
    );
  }

  /** Subscribes every configured account's events topic and starts its heartbeat sweep. */
  async start(): Promise<void> {
    await Promise.all(this.accounts.map((account) => this.startAccount(account)));
  }

  /** Stops every account's heartbeat sweep timer. Does not close `client` - the caller owns its lifecycle. */
  stop(): void {
    for (const state of this.states.values()) {
      this.scheduler.clearTimeout(state.sweepHandle);
    }
  }

  /** The `DeviceRegistry` for `account`, mainly for tests/inspection - `undefined` if `account` wasn't configured. */
  registryFor(account: string): DeviceRegistry | undefined {
    return this.states.get(account)?.registry;
  }

  /**
   * The `PriorityEngine` for one (account, resource), mainly for
   * tests/inspection. Defaults to `audio`, the only resource type any
   * adapter implements today.
   */
  engineFor(account: string, resource: ResourceType = RESOURCE_AUDIO): PriorityEngine | undefined {
    return this.states.get(account)?.resources.get(resource)?.engine;
  }

  private async startAccount(account: string): Promise<void> {
    const state: AccountState = {
      account,
      registry: new DeviceRegistry(),
      resources: new Map(),
      lastHeartbeatAt: new Map(),
      heartbeatSubscribed: new Set(),
      sweepHandle: undefined,
    };
    for (const resource of ALL_RESOURCE_TYPES) {
      state.resources.set(resource, {
        account,
        resource,
        // Wraps the injected scheduler so this engine's own internal
        // auto-return timer (private to PriorityEngine - there's no
        // public "holder changed" event to observe otherwise) also
        // triggers a holder-change check when it fires, without
        // PriorityEngine itself needing to know anything changed.
        engine: new PriorityEngine({ scheduler: this.observingScheduler(account, resource) }),
        lastHolder: null,
        publishedHolder: undefined,
      });
    }
    this.states.set(account, state);

    await this.client.subscribeAllEvents(account, (payload, node, resource) => {
      const forResource = state.resources.get(resource);
      // Unreachable via the parser, which validates the segment - but a
      // resource this process does not manage must be dropped rather
      // than silently creating state for it.
      if (!forResource) return;
      this.handleEvent(state, forResource, node, payload);
    });

    state.sweepHandle = this.scheduler.setTimeout(
      () => this.sweepHeartbeats(state),
      this.heartbeatSweepIntervalMs,
    );
  }

  private observingScheduler(account: string, resource: ResourceType): Scheduler {
    return {
      setTimeout: (callback, ms) =>
        this.scheduler.setTimeout(() => {
          callback();
          this.syncHolder(account, resource);
        }, ms),
      clearTimeout: (handle) => this.scheduler.clearTimeout(handle),
    };
  }

  private handleEvent(
    state: AccountState,
    resourceState: ResourceState,
    node: string,
    payload: unknown,
  ): void {
    if (isRegistrationPayload(payload)) {
      const holderBefore = resourceState.lastHolder;
      state.registry.register(payload.manifest);
      this.trackHeartbeat(state, node);

      // A registration means a fresh adapter process (#173). Two things
      // follow, and both are needed.
      //
      // First, reconcile this node's signals to what it says is actually
      // active. A fresh process reports nothing, which clears signals it
      // can no longer end itself (the monitor that would send the
      // matching `event_end` is gone, so they would pin the route to this
      // node forever). A *periodic* registration from a node that is
      // still playing reports that, so a relay which restarted - or whose
      // MQTT connection dropped and reconnected, which is how this was
      // found - learns about it again instead of staying blind (#178).
      resourceState.engine.reconcileSignals(node, activeEventsFrom(payload));
      this.syncHolder(state.account, resourceState.resource);

      // Second - the bug that made this visible - the relay's holder
      // state is durable but the node's actual Bluetooth connection is
      // not. A node that restarts while it is the holder comes back
      // holding nothing, and `syncHolder` above says nothing to it
      // because from the relay's point of view the holder never changed.
      // The node is then stuck: it never connects, and nothing can take
      // the route from it short of outranking it.
      //
      // So when the holder is unchanged *and* it is this node, re-assert
      // the claim. `claim` is idempotent for a node that really is
      // connected, which is what makes this safe to send unconditionally
      // here rather than trying to guess the device's true state.
      // #191 / ADR 0018 decision 2. Detection only - the *correction*
      // for the case that matters already exists and is not duplicated
      // here: the claim re-asserted just below is issued on every
      // registration from the holder, and the adapter now decides
      // whether to act on it from its actual route rather than a cached
      // belief (ADR 0018 decision 3). So a holder whose route has gone
      // repairs itself on the next registration.
      //
      // The opposite direction - a node that is *not* the holder
      // reporting that it does hold the route - is deliberately reported
      // and not acted on. ADR 0010's "local state wins" is about a
      // manual override, which ADR 0014's `claimMode` covers and is
      // still Proposed; and under multipoint two nodes can briefly both
      // report true. Moving the recorded holder on that basis would turn
      // a transient into a real switch.
      const holdsRoute = observedAudioRoute(payload);
      if (holdsRoute !== undefined) {
        const believedHolder = resourceState.lastHolder;
        const disagrees = holdsRoute ? believedHolder !== node : believedHolder === node;
        if (disagrees) {
          this.onRouteDrift({ account: state.account, node, nodeHoldsRoute: holdsRoute, believedHolder });
        }
      }

      if (resourceState.lastHolder === node && holderBefore === node) {
        this.client
          .publishCommand(state.account, node, resourceState.resource, { type: "claim" })
          .catch((error: unknown) => {
            logEvent("publish_failed", {
              account: state.account,
              resource: resourceState.resource,
              node,
              command: "claim",
              reason: "reassert",
              error: String(error),
            });
          });
      }

      // #222. Registration is the only thing that runs after a relay
      // restart without a holder change to trigger a publish, so it is
      // what overwrites a retained message left behind by the previous
      // process. A no-op once this process has published the current
      // holder - see `publishHolder`.
      this.publishHolder(resourceState);

      // #245. Last in the branch, so `holderAfter` reflects everything
      // above - reconcile, sync, the drift check and the re-assert.
      this.onRegistration({
        account: state.account,
        node,
        resource: resourceState.resource,
        platform: payload.manifest.platform,
        adapterVersion: payload.manifest.adapterVersion,
        activeEvents: activeEventsFrom(payload),
        observedRoutes: payload.observedRoutes ?? {},
        holderBefore,
        holderAfter: resourceState.lastHolder,
      });
      return;
    }
    // ADR 0019 / #206. Checked before the event guards below because an
    // outcome is a report *about* a command, not a trigger: it must not
    // touch arbitration. Deliberately no engine call and no syncHolder -
    // the relay records what happened and nothing else. Acting on an
    // outcome (retrying a failure, correcting on a timeout) is a
    // separate decision that ADR 0019 does not make.
    if (isCommandOutcomePayload(payload)) {
      this.onCommandOutcome({
        account: state.account,
        node,
        resource: resourceState.resource,
        epoch: payload.epoch,
        seq: payload.seq,
        outcome: payload.outcome,
        reason: payload.reason,
        durationMs: payload.durationMs,
      });
      return;
    }
    if (isEventEndPayload(payload)) {
      const holderBefore = resourceState.lastHolder;
      resourceState.engine.endEvent(node, payload.type);
      this.syncHolder(state.account, resourceState.resource);
      this.onNodeEvent({
        account: state.account,
        node,
        resource: resourceState.resource,
        kind: "event_end",
        type: payload.type,
        holderBefore,
        holderAfter: resourceState.lastHolder,
      });
      return;
    }
    if (isEventPayload(payload)) {
      const holderBefore = resourceState.lastHolder;
      resourceState.engine.recordEvent(node, payload.type);
      this.syncHolder(state.account, resourceState.resource);
      this.onNodeEvent({
        account: state.account,
        node,
        resource: resourceState.resource,
        kind: "event",
        type: payload.type,
        holderBefore,
        holderAfter: resourceState.lastHolder,
      });
      return;
    }
    // Unrecognized payload shape - dropped, not thrown, mirroring every
    // adapter's own "an unparseable message must not tear down the
    // subscription" discipline (e.g. AndroidNode.listenForCommands).
  }

  private trackHeartbeat(state: AccountState, node: string): void {
    state.lastHeartbeatAt.set(node, this.now());
    if (state.heartbeatSubscribed.has(node)) return;
    state.heartbeatSubscribed.add(node);
    // Fire-and-forget: the subscription itself is asynchronous (a real
    // MQTT SUBSCRIBE round-trip), but nothing here needs to block message
    // processing on it completing. `.catch` below only stops a transient
    // broker hiccup from becoming an unhandled rejection that crashes the
    // whole process (Node's default since v15) - it does not retry.
    this.client
      .subscribeHeartbeat(state.account, node, () => {
        state.lastHeartbeatAt.set(node, this.now());
      })
      .catch((error: unknown) => {
        logEvent("heartbeat_subscribe_failed", {
          account: state.account,
          node,
          error: String(error),
        });
      });
  }

  private sweepHeartbeats(state: AccountState): void {
    const now = this.now();
    let forgotAny = false;
    for (const [node, lastSeenAt] of state.lastHeartbeatAt) {
      const silentForMs = now - lastSeenAt;
      if (silentForMs < this.heartbeatTimeoutMs) continue;

      // Stale: three missed beats, so this node no longer counts as
      // live. Nothing here is destructive, and deliberately so (#263) -
      // being quiet is what a sleeping Mac and a dozing phone do all day.
      // Repeated on every sweep while the node stays quiet; `unregister`
      // is an idempotent Map delete, and nothing in production reads the
      // registry (it is inspection/test surface), so re-running it costs
      // nothing and needs no extra state to suppress.
      state.registry.unregister(node);

      // Not yet gone. The node keeps its signals, keeps the route if it
      // holds it, and keeps accumulating silence - `lastHeartbeatAt` is
      // deliberately not deleted here, because the next sweep needs to
      // know how long this has been going on.
      if (silentForMs < this.nodeDepartureTimeoutMs) continue;

      // Gone. Everything below this line is the destructive half, and is
      // the reason the two thresholds exist at all: `forgetNode` drops
      // the node's signals, which can move the route and publish a
      // RELEASE to a device that may still be using the headset.
      //
      // Previously only DeviceRegistry.unregister ran here -
      // PriorityEngine had no equivalent, so a node that went silent
      // mid-call could keep currentHolder() reporting it as the winner
      // forever (docs/handoffs/118.md's "Known gaps"). forgetNode (#130)
      // is that equivalent, and this is still bounded: "forever" became
      // 90s then, and 300s now.
      //
      // Every resource, not just one (#171). A heartbeat is evidence
      // about the *node* - whether its process is alive - not about
      // any resource it manages. A phone that has gone silent has gone
      // silent for audio and HID alike, so leaving it as the holder of
      // one while forgetting it from another would strand exactly the
      // stale-winner bug #130 closed.
      for (const resourceState of state.resources.values()) {
        resourceState.engine.forgetNode(node);
      }
      state.lastHeartbeatAt.delete(node);
      state.heartbeatSubscribed.delete(node);
      // #245. Emitted before the syncHolder below, so a reader sees the
      // cause immediately ahead of the holder_change it produces -
      // which is exactly the pairing #236 spent a day reconstructing.
      // Now emitted only for a departure, never for ordinary quiet, so
      // the line keeps meaning "a node lost its signals" rather than
      // "a phone's screen is off" (#263 criterion 4).
      this.onNodeReaped({
        account: state.account,
        node,
        silentForMs,
      });
      forgotAny = true;
    }
    // forgetNode can change currentHolder() synchronously (no auto-return
    // timer involved - see its own kdoc), unlike a normal recordEvent/
    // endEvent whose holder-change notification already rides
    // observingScheduler's wrapped timer callback. Nothing else calls
    // syncHolder after a sweep, so this is the one place that needs to.
    if (forgotAny) {
      for (const resourceState of state.resources.values()) {
        this.syncHolder(state.account, resourceState.resource);
      }
    }
    state.sweepHandle = this.scheduler.setTimeout(
      () => this.sweepHeartbeats(state),
      this.heartbeatSweepIntervalMs,
    );
  }

  private syncHolder(account: string, resource: ResourceType): void {
    const resourceState = this.states.get(account)?.resources.get(resource);
    if (!resourceState) return;

    const nextHolder = resourceState.engine.currentHolder();
    if (nextHolder === resourceState.lastHolder) return;

    const previousHolder = resourceState.lastHolder;
    resourceState.lastHolder = nextHolder;

    // Sequential handoff (ADR 0002 / architecture.md: "disconnect the
    // losing device, reconnect to the winning device") - RELEASE before
    // CLAIM, and only to the node(s) actually involved in this
    // transition. Fire-and-forget for the same reason trackHeartbeat's
    // subscribe call is: publish is a real MQTT round-trip this method
    // doesn't need to block on. Same `.catch` reasoning too - a failed
    // publish must not crash the process out from under every other
    // account this service is still managing.
    logEvent("holder_change", {
      account,
      resource,
      from: previousHolder,
      to: nextHolder,
    });

    if (previousHolder !== null) {
      this.client.publishCommand(account, previousHolder, resource, { type: "release" }).catch((error: unknown) => {
        logEvent("publish_failed", {
          account,
          resource,
          node: previousHolder,
          command: "release",
          error: String(error),
        });
      });
    }
    if (nextHolder !== null) {
      this.client.publishCommand(account, nextHolder, resource, { type: "claim" }).catch((error: unknown) => {
        logEvent("publish_failed", {
          account,
          resource,
          node: nextHolder,
          command: "claim",
          error: String(error),
        });
      });
    }

    this.publishHolder(resourceState);
  }

  /**
   * Announces who holds `resource` on the retained state topic (#222).
   *
   * `architecture.md`'s topic table and ADR 0001 have always specified
   * this topic; nothing published it until now, so nothing could
   * observe who holds a resource. A node only ever hears commands
   * addressed to itself, which tells it what it was told to do, not
   * what is true.
   *
   * ## Why it is retained, and what that costs
   *
   * Retained is what the spec asks for, and it is what lets a node that
   * has just connected learn the answer without waiting for the next
   * holder change.
   *
   * But a retained message **outlives the process that wrote it**, and
   * this relay holds all its state in memory (the premise of #178). So
   * after a restart the broker keeps serving the previous process's
   * answer while this process believes nothing, and every node
   * connecting in that window is handed an authoritative-looking
   * statement this relay would disown. That is #210's epoch problem in
   * a new place.
   *
   * The fix is `publishedHolder`'s third state. It starts `undefined`,
   * meaning "this process has published nothing", so the first call
   * after a restart always publishes - overwriting the stale retained
   * message - even when the value happens to match what is already
   * there. Thereafter only a genuine change publishes, so the steady
   * state is silent.
   *
   * ## Where this is called from
   *
   * Two places, and both are needed:
   *
   * - `syncHolder`, on a real holder change. The obvious one.
   * - Registration, which is the *only* thing that runs after a restart
   *   with no holder change to trigger it. Without it a relay that
   *   restarted during a quiet period would leave the stale message
   *   standing indefinitely - `syncHolder` returns early when the
   *   holder has not moved, so it would never be reached.
   *
   * Fire-and-forget with a `.catch`, for the same reason the command
   * publishes are: a failed publish must not crash the process out from
   * under every other account this service is managing. The consequence
   * of a lost state publish is a stale readout, not a missed switch.
   */
  private publishHolder(resourceState: ResourceState): void {
    if (resourceState.publishedHolder === resourceState.lastHolder) return;

    const holder = resourceState.lastHolder;
    resourceState.publishedHolder = holder;
    this.client
      .publishState(resourceState.account, resourceState.resource, { holder })
      .catch((error: unknown) => {
        // Rolled back so the next opportunity retries rather than
        // believing it has already announced this holder.
        resourceState.publishedHolder = undefined;
        console.error(
          `relay-hosted: failed to publish state for ${resourceState.account}/${resourceState.resource}`,
          error,
        );
      });
  }
}
