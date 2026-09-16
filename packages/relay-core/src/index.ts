import { PRIORITY_ORDER, type EventKind } from "@thrw/protocol";

export const relayCorePackageName = "@thrw/relay-core";

export { DeviceRegistry } from "./device-registry";

// Default auto-return timeout per architecture.md's "Priority rules" section
// ("auto-return: call_ended -> return to previous holder after a learned
// timeout (AI engine sets this per-user; default 90s)"). Per-user learned
// timeouts are services/ai-engine's job in a later milestone - this is only
// the default fallback.
export const DEFAULT_AUTO_RETURN_MS = 90_000;

// Injectable time source so the 90s auto-return timer never requires a test
// to wait on a real clock (see packages/testkit/test/sleep.test.ts for why
// real-timer assertions in this monorepo have already caused flaky CI).
export interface Scheduler {
  setTimeout(callback: () => void, ms: number): unknown;
  clearTimeout(handle: unknown): void;
}

export const systemScheduler: Scheduler = {
  setTimeout: (callback, ms) => setTimeout(callback, ms),
  clearTimeout: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

export interface PriorityEngineOptions {
  scheduler?: Scheduler;
  autoReturnMs?: number;
}

// Decision-only priority engine per docs/spec/architecture.md's "Priority
// rules" section. No MQTT client, no connection state machine (that's a
// frozen contract per ADR 0010/0011, and out of scope for this package) -
// just: which node is the rightful claim holder right now, given the active
// signals recorded across all nodes.
export class PriorityEngine {
  private readonly scheduler: Scheduler;
  private readonly autoReturnMs: number;

  // nodeId -> (event type -> insertion order), used both to know what's
  // active per node and to break ties when the same event kind is active
  // on more than one node (most recently started wins).
  private readonly signals = new Map<string, Map<EventKind, number>>();
  private orderCounter = 0;

  // Rule 5 fallback: the node that most recently held the claim.
  private lastClaimed: string | null = null;

  // Holder captured at the moment the current call session started, for
  // auto-return once it ends.
  private previousHolderBeforeCall: string | null = null;
  private cancelPendingReturn: (() => void) | null = null;

  constructor(options: PriorityEngineOptions = {}) {
    this.scheduler = options.scheduler ?? systemScheduler;
    this.autoReturnMs = options.autoReturnMs ?? DEFAULT_AUTO_RETURN_MS;
  }

  recordEvent(nodeId: string, type: EventKind): void {
    if (type === "call" && !this.hasActiveCallSomewhere()) {
      this.previousHolderBeforeCall = this.currentHolder();
    }

    // Any active signal is a rule 1-4 signal, and per architecture.md's
    // auto-return rule, any of those preempts a pending auto-return.
    this.clearPendingReturn();

    const nodeSignals = this.signals.get(nodeId) ?? new Map<EventKind, number>();
    nodeSignals.set(type, this.orderCounter++);
    this.signals.set(nodeId, nodeSignals);

    this.syncLastClaimed();
  }

  endEvent(nodeId: string, type: EventKind): void {
    this.signals.get(nodeId)?.delete(type);

    if (type === "call" && !this.hasActiveCallSomewhere()) {
      const previousHolder = this.previousHolderBeforeCall;
      this.previousHolderBeforeCall = null;
      if (previousHolder !== null && previousHolder !== nodeId) {
        this.scheduleReturn(previousHolder);
      }
    }

    this.syncLastClaimed();
  }

  currentHolder(): string | null {
    return this.computeActiveHolder() ?? this.lastClaimed;
  }

  private hasActiveCallSomewhere(): boolean {
    for (const nodeSignals of this.signals.values()) {
      if (nodeSignals.has("call")) return true;
    }
    return false;
  }

  private computeActiveHolder(): string | null {
    for (const kind of PRIORITY_ORDER) {
      let bestNode: string | null = null;
      let bestOrder = -1;
      for (const [nodeId, nodeSignals] of this.signals) {
        const order = nodeSignals.get(kind);
        if (order !== undefined && order > bestOrder) {
          bestOrder = order;
          bestNode = nodeId;
        }
      }
      if (bestNode !== null) return bestNode;
    }
    return null;
  }

  private syncLastClaimed(): void {
    const holder = this.computeActiveHolder();
    if (holder !== null) this.lastClaimed = holder;
  }

  private scheduleReturn(previousHolder: string): void {
    this.clearPendingReturn();
    const handle = this.scheduler.setTimeout(() => {
      this.cancelPendingReturn = null;
      this.lastClaimed = previousHolder;
    }, this.autoReturnMs);
    this.cancelPendingReturn = () => this.scheduler.clearTimeout(handle);
  }

  private clearPendingReturn(): void {
    this.cancelPendingReturn?.();
    this.cancelPendingReturn = null;
  }
}
