export const protocolPackageName = "@thrw/protocol";

// MQTT topic builders — see docs/spec/architecture.md, "MQTT topic design".
// The topic structure itself is a frozen contract (AGENTS.md, ADR 0001);
// changing the string shapes below requires a new ADR and human review.

/**
 * ADR 0015's resource types. `audio` is the headset connection thrw
 * manages today; `hid` is keyboard/mouse switching, which no adapter
 * implements yet.
 */
export type ResourceType = "audio" | "hid";

/** The headset audio connection - the only resource type in use. */
export const RESOURCE_AUDIO: ResourceType = "audio";

/**
 * Topics carrying a resource-type segment, per ADR 0015. This is the
 * breaking change to ADR 0001's structure that the ADR authorises, and
 * it is a flag day: a node on the old shape is invisible to a relay on
 * the new one, with no overlap window.
 *
 * Every string these produce is pinned in `fixtures/topics.json`, which
 * `adapter-mac` and `adapter-android`'s own builders assert against too -
 * there are three hand-written implementations of this contract and
 * nothing else would catch them drifting apart.
 */
export function eventsTopic(account: string, node: string, resource: ResourceType): string {
  return `thrw/${account}/nodes/${node}/${resource}/events`;
}

export function commandsTopic(account: string, node: string, resource: ResourceType): string {
  return `thrw/${account}/commands/${node}/${resource}`;
}

export function stateTopic(account: string, resource: ResourceType): string {
  return `thrw/${account}/state/${resource}`;
}

/**
 * Deliberately **without** a resource-type segment (ADR 0015 lists
 * exactly three topics that gain one). Liveness is a property of the
 * node - its process is running or it is not - not of any resource it
 * manages. Adding a segment here would also mean per-resource
 * heartbeats, multiplying traffic for no signal.
 */
export function heartbeatTopic(account: string, node: string): string {
  return `thrw/${account}/nodes/${node}/heartbeat`;
}

export const TopicQos = {
  events: { qos: 1 },
  commands: { qos: 1 },
  state: { retained: true },
  heartbeat: { qos: 0 },
} as const;

// Trigger categories from architecture.md's "Priority rules" section.
export type EventKind = "call" | "manual_claim" | "voip" | "media";

export type Priority = number;

// Single source of truth for priority ranking — call is highest priority.
// relay-core and adapters must import this rather than re-deriving their own.
export const PRIORITY_ORDER: readonly EventKind[] = [
  "call",
  "manual_claim",
  "voip",
  "media",
];

// New design decision for this issue — not a frozen contract.
export interface NodeManifest {
  nodeId: string;
  platform: "android" | "mac" | "ipad" | "linux";
  displayName: string;
  adapterVersion: string;
  supportedEventKinds: EventKind[];
  /**
   * Which resource types this adapter can actually *control* (ADR 0015).
   * Distinct from `supportedEventKinds`, which is what it can observe: a
   * Linux desktop might support `hid` but not `audio` if it has no
   * Bluetooth audio integration.
   */
  supportedResourceTypes: ResourceType[];
}

/**
 * How a claim or release ended (ADR 0019, #206).
 *
 * Every command resolves to exactly one of these within
 * {@link COMMAND_OUTCOME_TIMEOUT_MS}. Reported for **every** command,
 * not only failures: a success rate needs its denominator, and
 * "reliability" is otherwise inferred from the absence of complaints,
 * which lags real problems by however long a user tolerates silent
 * failure before reporting it.
 */
export type CommandOutcome = "succeeded" | "failed" | "timed_out";

/**
 * Why a `failed` outcome failed.
 *
 * A closed set rather than free text, because the whole point is to
 * aggregate: a rising rate for one reason on one device pairing is the
 * actionable signal (ADR 0019), and free-form strings do not group.
 */
export type CommandFailureReason =
  /** The local Bluetooth stack is off, unavailable, or refused the call. */
  | "bluetooth_unavailable"
  /** The headset did not accept the connection - off, out of range, busy. */
  | "target_device_unreachable"
  /**
   * A newer command for the same resource arrived first. ADR 0020's
   * coalescing produces this, and per that ADR it is tracked separately
   * from real failures - a superseded command is the debouncer working
   * correctly, not a switch that went wrong. The code exists now so it
   * is not retrofitted into data already being collected (#206
   * criterion 5).
   */
  | "superseded_by_newer_command";

/**
 * The bound every adapter enforces, identically (ADR 0019).
 *
 * Deliberately well above the 3-5s a claim actually takes to move the
 * audio route on the reference hardware. **It guarantees termination,
 * not latency** - latency has its own SLO and alert threshold in ADR
 * 0007, and conflating the two would report every slow-but-working
 * switch as a failure.
 *
 * Shared here rather than per-adapter so an outcome means the same
 * thing in every row of the resulting data. An adapter that picked its
 * own bound would silently make the aggregate meaningless.
 */
export const COMMAND_OUTCOME_TIMEOUT_MS = 8_000;

/**
 * A node's report of how a command ended (ADR 0019, #206).
 *
 * Rides the **events** topic. That is the only node-publishes topic in
 * the frozen set (ADR 0001/0015), and it already carries several
 * message kinds discriminated by `kind` (`register`, `event_end`), so
 * this follows that precedent rather than introducing a topic - no
 * change to the topic structure.
 *
 * `epoch` and `seq` identify *which* command this answers. They are the
 * same pair ADR 0018 point 1 added for idempotency (#211/#224), so a
 * relay that has restarted can tell an outcome for one of its own
 * commands from a late outcome for a previous process's.
 */
export interface CommandOutcomePayload {
  kind: "command_outcome";
  /** The relay epoch the answered command carried. */
  epoch: string;
  /** The sequence number the answered command carried. */
  seq: number;
  resourceType: ResourceType;
  outcome: CommandOutcome;
  /** Present when and only when `outcome` is `failed`. */
  reason?: CommandFailureReason;
  /** Wall time from receiving the command to resolving it. */
  durationMs: number;
}

/** The `kind` discriminator for {@link CommandOutcomePayload}. */
export const COMMAND_OUTCOME_KIND = "command_outcome";

// Method signatures only, per architecture.md's "System components" section.
// The connection state machine (idle/pre-claim/claim/active/cooldown) is a
// frozen contract (ADR 0010/0011) and is intentionally not implemented here.
export interface NodeInterface {
  register(manifest: NodeManifest): void;
  emitEvent(type: EventKind, priority: Priority): void;
  onClaim(): void;
  onRelease(): void;
}

// Connection state machine — see docs/spec/architecture.md's "Connection
// state machine" section and ADR 0013. Exactly these four states; no
// "cooldown" state (ADR 0010's self-cooldown window is adapter-local
// implementation detail layered around onClaim/onRelease, out of scope
// for this shared type). This is a frozen contract (AGENTS.md).
export type ConnectionState = "idle" | "pre-claim" | "claim" | "active";

const LEGAL_TRANSITIONS: ReadonlyMap<
  ConnectionState,
  ReadonlySet<ConnectionState>
> = new Map([
  ["idle", new Set<ConnectionState>(["pre-claim"])],
  ["pre-claim", new Set<ConnectionState>(["claim", "idle"])],
  ["claim", new Set<ConnectionState>(["active"])],
  ["active", new Set<ConnectionState>(["idle"])],
]);

export class IllegalConnectionTransitionError extends Error {
  constructor(
    public readonly from: ConnectionState,
    public readonly to: ConnectionState,
  ) {
    super(`Illegal connection state transition: ${from} -> ${to}`);
    this.name = "IllegalConnectionTransitionError";
  }
}

// Pure in-memory state container — no MQTT, no OS/Bluetooth integration.
// Adapters (later milestones) own the I/O; this only enforces which
// transitions are legal.
export class ConnectionStateMachine {
  #state: ConnectionState;

  constructor(initial: ConnectionState = "idle") {
    this.#state = initial;
  }

  get state(): ConnectionState {
    return this.#state;
  }

  canTransition(to: ConnectionState): boolean {
    return LEGAL_TRANSITIONS.get(this.#state)?.has(to) ?? false;
  }

  transition(to: ConnectionState): ConnectionState {
    if (!this.canTransition(to)) {
      throw new IllegalConnectionTransitionError(this.#state, to);
    }
    this.#state = to;
    return this.#state;
  }
}
