import { PRIORITY_ORDER, type EventKind } from "@thrw/protocol";

export const relayCorePackageName = "@thrw/relay-core";

// The missing ".js" here (present two lines down on mqtt-client.js's own
// export) broke `node dist/index.js` under real Node ESM resolution -
// found while wiring services/relay-hosted's live process (#118), the
// first thing to ever actually run relay-core's *compiled* dist/ output
// rather than importing its TS source directly (vitest/vite's resolver
// tolerates an extensionless relative import; Node's real ESM loader
// does not). Every other consumer of this package until now was either
// a test (vitest) or another package's own TS source, neither of which
// exercised this path. Fixed per #118 acceptance criterion 6's explicit
// allowance ("unless you find a real bug while wiring this up").
export { DeviceRegistry } from "./device-registry.js";
export {
  CommandCoalescer,
  DEFAULT_CLAIM_WINDOW_MS,
  DEFAULT_RELEASE_WINDOW_MS,
  type CoalescedCommand,
  type CommandCoalescerOptions,
  type CommandKind,
} from "./command-coalescer.js";
export {
  RelayMqttClient,
  defaultMqttBrokerUrl,
  type CommandPayload,
  type EventPayload,
  type HeartbeatListener,
  type NodeEventListener,
  type StatePayload,
} from "./mqtt-client.js";

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

  /**
   * Removes `nodeId` entirely from tracked signals - for a node that has
   * gone silent (missed heartbeats) rather than sent a normal
   * `event_end` for whatever it had active (#130, closing the gap
   * `docs/handoffs/118.md`'s "Known gaps" flagged: nothing else here
   * ever stops reporting a vanished node as the winner).
   *
   * Unlike `endEvent`, which clears one signal kind on a node the relay
   * still expects to hear from again, this treats the node as gone from
   * the system altogether: it can no longer be reported as the current
   * holder by any means, including the rule-5 last-claimed fallback -
   * `syncLastClaimed` alone would leave that fallback stale here, since
   * it only ever *sets* `lastClaimed`, never clears it (see its own
   * implementation below).
   *
   * Judgment call (acceptance criterion 3): a node going silent mid-call
   * is *not* treated the same as a normal call end. The 90s auto-return
   * grace period (`recordEvent`/`endEvent`'s `scheduleReturn`) exists to
   * avoid yanking a claim away right after a *graceful* end, in case the
   * same node reclaims it again almost immediately. A silently-departed
   * node has no session left to protect, so the previous holder gets the
   * claim back immediately here rather than waiting out
   * `DEFAULT_AUTO_RETURN_MS` for no reason.
   */
  forgetNode(nodeId: string): void {
    this.dropSignals(nodeId);
  }

  /**
   * Clears everything `nodeId` had active because its adapter **restarted**
   * - as opposed to `forgetNode`'s "it went silent and is gone" (#173).
   *
   * A registration is the signal: a node registers once per node-runtime
   * start (`NodeRuntime`), never on an MQTT reconnect, so a registration
   * from a node the relay already knows about means a fresh process. A
   * fresh process has no active triggers - whatever it had recorded here
   * can never be ended by an `event_end`, because the monitor that would
   * have sent one no longer exists. Left in place, a stale signal pins
   * the route to that node permanently.
   *
   * The one difference from `forgetNode`, and the whole reason this
   * exists separately: **`lastClaimed` is preserved**. The node is still
   * here. Clearing the rule-5 fallback would move the headset away from
   * the device you are actually using every time its app restarted;
   * keeping it means the relay still considers this node the holder and
   * can re-assert the claim, which is what
   * `RelayService.handleEvent` does on the back of this.
   */
  restartNode(nodeId: string): void {
    this.reconcileSignals(nodeId, []);
  }

  /**
   * Sets `nodeId`'s active signals to exactly `active`, preserving the
   * rule-5 fallback (#178).
   *
   * Every registration carries the node's currently-active triggers, so
   * this is what the relay applies on each one. It makes the relay's view
   * *converge* on the node's own view rather than being inferred from a
   * stream of edges it may have missed - which is the whole point:
   * a relay that restarts, or whose MQTT connection drops and
   * reconnects, has no idea what is playing anywhere, and nothing else
   * ever tells it.
   *
   * A fresh process sends an empty set, which is exactly `restartNode`
   * above and keeps #173's behaviour intact.
   *
   * **Signals present in both keep their original insertion order.** That
   * order is the tie-break for "same event kind active on more than one
   * node, most recently started wins", so re-stamping it on every
   * periodic registration would make whichever node registered last look
   * like the most recent starter and silently steal the route.
   */
  reconcileSignals(nodeId: string, active: readonly EventKind[]): void {
    const existing = this.signals.get(nodeId);
    const wanted = new Set(active);
    if (!existing && wanted.size === 0) return;

    const hadActiveCall = existing?.has("call") ?? false;
    const nodeSignals = existing ?? new Map<EventKind, number>();

    for (const kind of [...nodeSignals.keys()]) {
      if (!wanted.has(kind)) nodeSignals.delete(kind);
    }
    for (const kind of wanted) {
      if (!nodeSignals.has(kind)) nodeSignals.set(kind, this.orderCounter++);
    }

    if (nodeSignals.size === 0) this.signals.delete(nodeId);
    else this.signals.set(nodeId, nodeSignals);

    // Same auto-return handling as a node going away mid-call: the call
    // is over and this node is back, so the pre-call holder is released
    // immediately rather than waiting out the grace period that exists
    // to protect a *graceful* end.
    if (hadActiveCall && !this.hasActiveCallSomewhere()) {
      this.previousHolderBeforeCall = null;
    }

    this.syncLastClaimed();
    // lastClaimed is deliberately never cleared here - see restartNode.
  }

  private dropSignals(nodeId: string): void {
    const nodeSignals = this.signals.get(nodeId);
    if (!nodeSignals) return;

    const hadActiveCall = nodeSignals.has("call");
    this.signals.delete(nodeId);

    let immediateFallback: string | null = null;
    if (hadActiveCall && !this.hasActiveCallSomewhere()) {
      immediateFallback = this.previousHolderBeforeCall;
      this.previousHolderBeforeCall = null;
    }

    this.syncLastClaimed();

    // syncLastClaimed only ever *sets* lastClaimed when there's an active
    // holder (see its own implementation) - it was never meant to detect
    // "the thing it's currently pointing at no longer exists". That's
    // this method's own job: only forgetNode (not endEvent) means the
    // node itself is gone, not just one of its signals.
    //
    // A restart is precisely the case where it is *not* gone, so the
    // fallback is left pointing at it - see restartNode's own doc.
    if (this.lastClaimed === nodeId) {
      this.lastClaimed = this.computeActiveHolder() ?? immediateFallback;
    }
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
