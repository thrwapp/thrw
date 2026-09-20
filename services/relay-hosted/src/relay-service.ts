import {
  DeviceRegistry,
  PriorityEngine,
  systemScheduler,
  type EventPayload,
  type RelayMqttClient,
  type Scheduler,
} from "@thrw/relay-core";
import { PRIORITY_ORDER } from "@thrw/protocol";
import type { EventKind, NodeManifest } from "@thrw/protocol";

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

interface AccountState {
  readonly account: string;
  readonly registry: DeviceRegistry;
  readonly engine: PriorityEngine;
  lastHolder: string | null;
  readonly lastHeartbeatAt: Map<string, number>;
  readonly heartbeatSubscribed: Set<string>;
  sweepHandle: unknown;
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
  private readonly scheduler: Scheduler;
  private readonly heartbeatTimeoutMs: number;
  private readonly heartbeatSweepIntervalMs: number;
  private readonly states = new Map<string, AccountState>();

  constructor(options: RelayServiceOptions) {
    this.client = options.client;
    this.accounts = options.accounts;
    this.now = options.now ?? (() => Date.now());
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

  /** The `PriorityEngine` for `account`, mainly for tests/inspection - `undefined` if `account` wasn't configured. */
  engineFor(account: string): PriorityEngine | undefined {
    return this.states.get(account)?.engine;
  }

  private async startAccount(account: string): Promise<void> {
    const state: AccountState = {
      account,
      registry: new DeviceRegistry(),
      // Wraps the injected scheduler so this engine's own internal
      // auto-return timer (private to PriorityEngine - there's no public
      // "holder changed" event to observe otherwise) also triggers a
      // holder-change check when it fires, without PriorityEngine itself
      // needing to know anything changed.
      engine: new PriorityEngine({ scheduler: this.observingScheduler(account) }),
      lastHolder: null,
      lastHeartbeatAt: new Map(),
      heartbeatSubscribed: new Set(),
      sweepHandle: undefined,
    };
    this.states.set(account, state);

    await this.client.subscribeAllEvents(account, (payload, node) => {
      this.handleEvent(state, node, payload);
    });

    state.sweepHandle = this.scheduler.setTimeout(
      () => this.sweepHeartbeats(state),
      this.heartbeatSweepIntervalMs,
    );
  }

  private observingScheduler(account: string): Scheduler {
    return {
      setTimeout: (callback, ms) =>
        this.scheduler.setTimeout(() => {
          callback();
          this.syncHolder(account);
        }, ms),
      clearTimeout: (handle) => this.scheduler.clearTimeout(handle),
    };
  }

  private handleEvent(state: AccountState, node: string, payload: unknown): void {
    if (isRegistrationPayload(payload)) {
      const holderBefore = state.lastHolder;
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
      state.engine.reconcileSignals(node, activeEventsFrom(payload));
      this.syncHolder(state.account);

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
      if (state.lastHolder === node && holderBefore === node) {
        this.client.publishCommand(state.account, node, { type: "claim" }).catch((error: unknown) => {
          console.error(`relay-hosted: failed to re-publish claim to ${state.account}/${node}`, error);
        });
      }
      return;
    }
    if (isEventEndPayload(payload)) {
      state.engine.endEvent(node, payload.type);
      this.syncHolder(state.account);
      return;
    }
    if (isEventPayload(payload)) {
      state.engine.recordEvent(node, payload.type);
      this.syncHolder(state.account);
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
        state.engine.forgetNode(node);
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
    if (forgotAny) this.syncHolder(state.account);
    state.sweepHandle = this.scheduler.setTimeout(
      () => this.sweepHeartbeats(state),
      this.heartbeatSweepIntervalMs,
    );
  }

  private syncHolder(account: string): void {
    const state = this.states.get(account);
    if (!state) return;

    const nextHolder = state.engine.currentHolder();
    if (nextHolder === state.lastHolder) return;

    const previousHolder = state.lastHolder;
    state.lastHolder = nextHolder;

    // Sequential handoff (ADR 0002 / architecture.md: "disconnect the
    // losing device, reconnect to the winning device") - RELEASE before
    // CLAIM, and only to the node(s) actually involved in this
    // transition. Fire-and-forget for the same reason trackHeartbeat's
    // subscribe call is: publish is a real MQTT round-trip this method
    // doesn't need to block on. Same `.catch` reasoning too - a failed
    // publish must not crash the process out from under every other
    // account this service is still managing.
    if (previousHolder !== null) {
      this.client.publishCommand(account, previousHolder, { type: "release" }).catch((error: unknown) => {
        console.error(`relay-hosted: failed to publish release to ${account}/${previousHolder}`, error);
      });
    }
    if (nextHolder !== null) {
      this.client.publishCommand(account, nextHolder, { type: "claim" }).catch((error: unknown) => {
        console.error(`relay-hosted: failed to publish claim to ${account}/${nextHolder}`, error);
      });
    }
  }
}
