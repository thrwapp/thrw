export const protocolPackageName = "@thrw/protocol";

// MQTT topic builders — see docs/spec/architecture.md, "MQTT topic design".
// The topic structure itself is a frozen contract (AGENTS.md, ADR 0001);
// changing the string shapes below requires a new ADR and human review.

export function eventsTopic(account: string, node: string): string {
  return `thrw/${account}/nodes/${node}/events`;
}

export function commandsTopic(account: string, node: string): string {
  return `thrw/${account}/commands/${node}`;
}

export function stateTopic(account: string): string {
  return `thrw/${account}/state`;
}

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
}

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
