import {
  DeviceRegistry,
  PriorityEngine,
  systemScheduler,
  type EventPayload,
  type RelayMqttClient,
  type Scheduler,
} from "@thrw/relay-core";
import { PRIORITY_ORDER } from "@thrw/protocol";
import { RESOURCE_AUDIO } from "@thrw/protocol";
import type { EventKind, NodeManifest, ResourceType } from "@thrw/protocol";

// #118: the actual long-running decision service - subscribes to every
// registered node's events per account, drives one PriorityEngine per
// account, and publishes CLAIM/RELEASE back to whichever node(s) the
// resulting holder change concerns. Not new arbitration logic (#113/#114
// already proved PriorityEngine/RelayMqttClient work together over a real
// broker) - this is packaging that logic as a live subscriber.

const REGISTRATION_KIND = "register";
const EVENT_END_KIND = "event_end";

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
// beats is normal jitter, three in a row is "gone". A judgment call
// (#118 acceptance criterion 2 explicitly asks for one, since the wire
// protocol has no explicit "goodbye" message) - not derived from any
// measurement, just a round multiple of the documented interval.
const DEFAULT_HEARTBEAT_TIMEOUT_MS = 90_000;

// How often each account's registry is swept for timed-out nodes. Well
// under the timeout itself so a departed node isn't left registered much
// longer than DEFAULT_HEARTBEAT_TIMEOUT_MS actually implies.
const DEFAULT_HEARTBEAT_SWEEP_INTERVAL_MS = 15_000;

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
   * Injectable scheduler - used both for each account's `PriorityEngine`
   * (its own auto-return timer) and for the heartbeat sweep, so a test can
   * control both deterministically with one fake, the same pattern
   * `packages/relay-core/test/handoff-integration.test.ts` already uses
   * for `PriorityEngine` alone.
   */
  scheduler?: Scheduler;
  heartbeatTimeoutMs?: number;
  heartbeatSweepIntervalMs?: number;
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
  private readonly scheduler: Scheduler;
  private readonly heartbeatTimeoutMs: number;
  private readonly heartbeatSweepIntervalMs: number;
  private readonly states = new Map<string, AccountState>();

  constructor(options: RelayServiceOptions) {
    this.client = options.client;
    this.accounts = options.accounts;
    this.now = options.now ?? (() => Date.now());
    this.onRouteDrift =
      options.onRouteDrift ??
      ((drift) => {
        console.warn(
          `relay-hosted: route drift on ${drift.account} - ${drift.node} reports ` +
            `holdsRoute=${drift.nodeHoldsRoute} while the recorded holder is ` +
            `${drift.believedHolder ?? "(none)"}`,
        );
      });
    this.scheduler = options.scheduler ?? systemScheduler;
    this.heartbeatTimeoutMs = options.heartbeatTimeoutMs ?? DEFAULT_HEARTBEAT_TIMEOUT_MS;
    this.heartbeatSweepIntervalMs = options.heartbeatSweepIntervalMs ?? DEFAULT_HEARTBEAT_SWEEP_INTERVAL_MS;
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
          console.error(`relay-hosted: failed to re-publish claim to ${state.account}/${node}`, error);
        });
      }
      return;
    }
    if (isEventEndPayload(payload)) {
      resourceState.engine.endEvent(node, payload.type);
      this.syncHolder(state.account, resourceState.resource);
      return;
    }
    if (isEventPayload(payload)) {
      resourceState.engine.recordEvent(node, payload.type);
      this.syncHolder(state.account, resourceState.resource);
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
        console.error(`relay-hosted: heartbeat subscribe failed for ${state.account}/${node}`, error);
      });
  }

  private sweepHeartbeats(state: AccountState): void {
    const cutoff = this.now() - this.heartbeatTimeoutMs;
    let forgotAny = false;
    for (const [node, lastSeenAt] of state.lastHeartbeatAt) {
      if (lastSeenAt < cutoff) {
        // Acceptance criterion 2's "gone" definition: three missed
        // heartbeat intervals. Previously only DeviceRegistry.unregister
        // ran here - PriorityEngine had no equivalent, so a node that
        // went silent mid-call could keep currentHolder() reporting it
        // as the winner forever (docs/handoffs/118.md's "Known gaps").
        // PriorityEngine.forgetNode (#130) is that equivalent.
        state.registry.unregister(node);
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
        forgotAny = true;
      }
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
    if (previousHolder !== null) {
      this.client.publishCommand(account, previousHolder, resource, { type: "release" }).catch((error: unknown) => {
        console.error(`relay-hosted: failed to publish release to ${account}/${previousHolder}`, error);
      });
    }
    if (nextHolder !== null) {
      this.client.publishCommand(account, nextHolder, resource, { type: "claim" }).catch((error: unknown) => {
        console.error(`relay-hosted: failed to publish claim to ${account}/${nextHolder}`, error);
      });
    }
  }
}
