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
