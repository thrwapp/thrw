import {
  commandsTopic,
  eventsTopic,
  heartbeatTopic,
  stateTopic,
  type ResourceType,
} from "@thrw/protocol";
import {
  CommandSequencer,
  type CommandPayload,
  type HeartbeatListener,
  type NodeEventListener,
  type RelayTransport,
  type SequencedCommandPayload,
  type StatePayload,
} from "@thrw/relay-core";
import type { VirtualClock } from "./virtual-clock.js";

/** A command the relay dispatched, as it would have gone on the wire. */
export interface DispatchedCommand {
  account: string;
  node: string;
  resource: ResourceType;
  payload: SequencedCommandPayload;
  /** Virtual time the relay published it, so a scenario can assert on ordering and latency. */
  atMs: number;
}

/** A retained state publication, in order. */
export interface PublishedState {
  account: string;
  resource: ResourceType;
  payload: StatePayload;
  atMs: number;
}

export interface InMemoryBusOptions {
  clock: VirtualClock;
  /**
   * Virtual milliseconds between a publish and its delivery. Zero by
   * default: message transit is not what most scenarios are about, and a
   * default delay would silently add itself to every timing assertion.
   *
   * Non-zero is how a scenario models the relay and a node disagreeing
   * because a message is still in flight — which is the shape of #307
   * (the relay believing a holder that had already lost the route) and of
   * #308's candidate explanation (a UI refreshing while a route change is
   * still settling).
   */
  deliveryDelayMs?: number;
}

/**
 * {@link RelayTransport} with no broker, on a virtual clock (#320).
 *
 * The relay's real decision logic — `RelayService`, `PriorityEngine`,
 * `CommandCoalescer`, `DeviceRegistry` — runs against this unmodified,
 * which is the whole point: a scenario exercises the code that ships, not
 * a model of it (`docs/spec/testing-framework.md`).
 *
 * ## Two surfaces, deliberately
 *
 * - The **relay** side is {@link RelayTransport}: the four methods
 *   `RelayService` calls. Nothing here widens that.
 * - The **node** side is the `node*` methods below, which a scenario uses
 *   to make a simulated device speak. They are not part of
 *   `RelayTransport` because publishing an event is something a node does;
 *   giving the relay's interface a `publishEvent` would let a test drive
 *   the relay through a method the real relay never calls.
 *
 * ## Delivery is scheduled through the clock, not queued separately
 *
 * Every publish becomes a `clock.setTimeout`. That is what makes message
 * delivery and the relay's own timers — coalescing windows, the heartbeat
 * sweep, the 90s auto-return — interleave in correct time order under a
 * single `clock.advance()`, rather than the bus draining as a separate
 * phase and every scenario having to know which to pump first.
 *
 * Topics are built with `@thrw/protocol`'s real builders rather than
 * compared as tuples, so a scenario also exercises the topic contract
 * (ADR 0015's resource segment included) instead of routing around it.
 */
export class InMemoryBus implements RelayTransport {
  /**
   * The same sequencer production uses, not a reimplementation — ADR
   * 0018's numbering is exactly the kind of thing a simulator must not
   * get subtly right-looking-but-different, since every idempotency test
   * run against it would then be testing the wrong scheme.
   */
  readonly sequencer = new CommandSequencer();

  /** Every command the relay dispatched, in order. */
  readonly commands: DispatchedCommand[] = [];

  /** Every retained state publication, in order. */
  readonly states: PublishedState[] = [];

  private readonly clock: VirtualClock;
  private readonly deliveryDelayMs: number;
  /** account -> listeners on that account's wildcard events subscription. */
  private readonly eventListeners = new Map<string, NodeEventListener[]>();
  /** heartbeat topic -> listeners. */
  private readonly heartbeatListeners = new Map<string, HeartbeatListener[]>();
  /** Commands topic -> listeners, for a scenario that wants to act as a node receiving them. */
  private readonly commandListeners = new Map<string, ((p: SequencedCommandPayload) => void)[]>();

  constructor(options: InMemoryBusOptions) {
    this.clock = options.clock;
    this.deliveryDelayMs = options.deliveryDelayMs ?? 0;
  }

  // ---- RelayTransport: the relay's side ----

  subscribeAllEvents(account: string, onMessage: NodeEventListener): Promise<unknown> {
    const existing = this.eventListeners.get(account);
    if (existing) existing.push(onMessage);
    else this.eventListeners.set(account, [onMessage]);
    return Promise.resolve();
  }

  subscribeHeartbeat(
    account: string,
    node: string,
    onMessage: HeartbeatListener,
  ): Promise<unknown> {
    const topic = heartbeatTopic(account, node);
    const existing = this.heartbeatListeners.get(topic);
    if (existing) existing.push(onMessage);
    else this.heartbeatListeners.set(topic, [onMessage]);
    return Promise.resolve();
  }

  publishCommand(
    account: string,
    node: string,
    resource: ResourceType,
    payload: CommandPayload,
  ): Promise<void> {
    const sequenced = this.sequencer.stamp(account, node, resource, payload);
    this.commands.push({ account, node, resource, payload: sequenced, atMs: this.clock.now() });

    const topic = commandsTopic(account, node, resource);
    this.deliver(() => {
      for (const listener of this.commandListeners.get(topic) ?? []) listener(sequenced);
    });
    return Promise.resolve();
  }

  publishState(account: string, resource: ResourceType, payload: StatePayload): Promise<void> {
    // Recorded rather than delivered: `state` is retained and read by
    // adapters, and no relay-side code subscribes to it. A node model that
    // needs it reads `latestState` instead.
    this.states.push({ account, resource, payload, atMs: this.clock.now() });
    // Referenced so the topic builder is exercised even though nothing
    // routes on it yet - a resource-segment regression (ADR 0015) should
    // fail here too, not only in the topic fixture tests.
    void stateTopic(account, resource);
    return Promise.resolve();
  }

  // ---- The node's side: what a scenario drives ----

  /**
   * A node publishes on its own events topic. Takes an arbitrary payload
   * rather than a typed `EventPayload` on purpose: that topic legitimately
   * carries several shapes discriminated by `kind` (`register`,
   * `event_end`, `command_outcome`), and a scenario must be able to send a
   * malformed one to check the relay drops it rather than throwing.
   */
  nodePublishes(
    account: string,
    node: string,
    resource: ResourceType,
    payload: unknown,
  ): void {
    // Built and parsed rather than passed straight through, so the
    // relay-side listener receives the node and resource the same way
    // production does - by the wildcard subscription parsing a real topic.
    void eventsTopic(account, node, resource);
    this.deliver(() => {
      for (const listener of this.eventListeners.get(account) ?? []) {
        listener(payload, node, resource);
      }
    });
  }

  /** A node's liveness beat. `RelayService` only cares that one arrived. */
  nodeHeartbeat(account: string, node: string, payload: unknown = {}): void {
    const topic = heartbeatTopic(account, node);
    this.deliver(() => {
      for (const listener of this.heartbeatListeners.get(topic) ?? []) listener(payload, topic);
    });
  }

  /** Lets a scenario act as a node receiving commands, for asserting what a device would have been told. */
  onCommand(
    account: string,
    node: string,
    resource: ResourceType,
    listener: (payload: SequencedCommandPayload) => void,
  ): void {
    const topic = commandsTopic(account, node, resource);
    const existing = this.commandListeners.get(topic);
    if (existing) existing.push(listener);
    else this.commandListeners.set(topic, [listener]);
  }

  // ---- Observation ----

  /** The most recent retained state for a resource, or `undefined` if none was ever published. */
  latestState(account: string, resource: ResourceType): StatePayload | undefined {
    for (let i = this.states.length - 1; i >= 0; i -= 1) {
      const entry = this.states[i];
      if (entry !== undefined && entry.account === account && entry.resource === resource) {
        return entry.payload;
      }
    }
    return undefined;
  }

  /** Commands dispatched to one node, in order. */
  commandsTo(account: string, node: string, resource: ResourceType): DispatchedCommand[] {
    return this.commands.filter(
      (c) => c.account === account && c.node === node && c.resource === resource,
    );
  }

  private deliver(action: () => void): void {
    if (this.deliveryDelayMs === 0) {
      // Still through the clock rather than called inline: a publish made
      // from inside a timer callback must not re-enter the relay in the
      // middle of that callback, which is a reentrancy production does not
      // have (a real broker round-trip always yields).
      this.clock.setTimeout(action, 0);
      return;
    }
    this.clock.setTimeout(action, this.deliveryDelayMs);
  }
}
