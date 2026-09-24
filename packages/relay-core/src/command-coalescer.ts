import type { Scheduler } from "./index.js";

/**
 * ADR 0020 decision 1: the relay coalesces claim/release commands for the
 * same (account, node, resource_type) so it does not dispatch a command that
 * has already stopped being relevant.
 *
 * ## What this is not
 *
 * `superseded_by_newer_command` already existed before this, and it is a
 * *different* mechanism: ADR 0018's sequence gate, running **adapter-side**.
 * There, the node receives the stale command and discards it by sequence
 * number. Here, the relay does not send it at all. Both are wanted - the
 * sequence gate is the backstop for anything this misses, including a command
 * already in flight over MQTT - and the telemetry existing was never evidence
 * that this decision was done.
 *
 * ## Leading edge, not trailing
 *
 * The first command for an idle key dispatches **immediately**. Only commands
 * arriving while a previous one is still settling are held. That ordering is
 * the whole design constraint: a trailing debounce would add its window to
 * every ordinary switch, spending ADR 0007's 3.5-4s p95 claim budget to fix a
 * burst case that is rare. A single trigger must cost nothing, and here it
 * costs nothing.
 *
 * ## Only claims are ever held. A release always goes out at once.
 *
 * This narrows ADR 0020's "coalesces claim/release commands", and the reason is
 * ADR 0002: handoff is **sequential**, so the winning device cannot take the
 * route until the losing device has let go. A held release therefore does not
 * damp a burst - it stalls the whole handoff, and the claim waiting behind it,
 * for the length of the window.
 *
 * That is not a hypothetical. Coalescing both directions fails
 * relay-hosted's "publishes CLAIM to the first holder, then RELEASE+CLAIM on a
 * real handoff" test: a second device wanting the headset within 6s of the
 * first getting it had its predecessor's release deferred, so nothing moved.
 * A switch that ordinarily takes ~4.9s would have taken ~11s.
 *
 * It is also the right behaviour on its own terms. A release means the user has
 * moved on, so executing it late is never what they wanted - #254's handoff
 * makes the same argument for why a release silences audio and never restores
 * it. And a release is cheap and idempotent, where a claim is the slow,
 * contended operation whose repeated execution is the thrash the ADR is about.
 *
 * So a burst collapses to: every release as it happens, plus at most one claim
 * per window. Superseded claims are dropped and reported.
 *
 * ## The window is asymmetric, and both figures are measured
 *
 * ADR 0020 originally took ~3s from ADR 0010's cooldown for both directions;
 * its 2026-09-20 amendment says that is right for a release and too short for
 * a claim, and asks for the claim side to be "derived from observed settle
 * time rather than inheriting the release-side figure".
 *
 * That measurement now exists (#254, `docs/handoffs/254.md`), taken from both
 * adapters' own `command_outcome` reports rather than from two unsynchronised
 * clocks:
 *
 *   - Mac release, command to outcome `succeeded`: **~2.2s**
 *   - Pixel claim, command to outcome `succeeded`: **~4.9s**
 *
 * A window shorter than the settle time it covers is the bug being fixed: the
 * next command arrives while the route is still moving, which is exactly the
 * +4s and +5s duplicate `media` events the amendment recorded.
 *
 * Hence {@link DEFAULT_RELEASE_WINDOW_MS} 3000 (covers 2.2s) and
 * {@link DEFAULT_CLAIM_WINDOW_MS} 6000 (covers 4.9s, and the +5s re-fire).
 *
 * Honest about what that 4.9s is: **one measurement, on one pair of devices,
 * with no distribution behind it** - #254's own handoff says exactly that. The
 * headroom on the claim side exists because of that, not despite it, and both
 * windows are constructor options so a real distribution can replace a guess
 * without a code change.
 */
export type CommandKind = "claim" | "release";

/** Covers the ~2.2s measured Mac release (#254). */
export const DEFAULT_RELEASE_WINDOW_MS = 3_000;

/**
 * Covers the ~4.9s measured Pixel claim (#254) with ~22% headroom, and the
 * +5s media re-fire ADR 0020's amendment observed.
 *
 * Deliberately not 5000: that would sit ~2% above a single measurement, so any
 * device slower than the one sample would land outside its own window.
 */
export const DEFAULT_CLAIM_WINDOW_MS = 6_000;

/**
 * A command the relay chose not to publish.
 *
 * Reported rather than silently dropped, per ADR 0019: coalescing is not a
 * failure and must not be counted as one, but a high rate here is real signal
 * about how bursty the triggers are.
 */
export interface CoalescedCommand {
  readonly account: string;
  readonly node: string;
  readonly resource: string;
  /** The command that was not published. */
  readonly dropped: CommandKind;
  /**
   * Why it was not published.
   *
   * - `superseded_by_newer_command` - a newer command for this key replaced it
   *   before the window closed. Same vocabulary as ADR 0019's reason code, for
   *   a relay-side decision rather than an adapter-side one.
   * - `already_in_target_state` - the window closed and the coalesced intent
   *   matched what this node was last told, so there was nothing to send.
   */
  readonly reason: "superseded_by_newer_command" | "already_in_target_state";
}

export interface CommandCoalescerOptions {
  /** Publishes a command. Called synchronously for a leading-edge dispatch. */
  dispatch: (account: string, node: string, resource: string, kind: CommandKind) => void;
  /** Called for every command not published. Defaults to a no-op. */
  onCoalesced?: (coalesced: CoalescedCommand) => void;
  claimWindowMs?: number;
  releaseWindowMs?: number;
  now?: () => number;
  scheduler?: Scheduler;
}

interface KeyState {
  lastDispatched: CommandKind;
  lastDispatchedAt: number;
  pending?: CommandKind;
  timer?: unknown;
}

/**
 * Keyed on (account, node, resource_type), exactly as ADR 0020 specifies.
 *
 * Holds no MQTT and no arbitration state: it decides *when* a command may go
 * out, and the caller decides what to send. Same split as `PriorityEngine`,
 * and the reason both are unit-testable against an injected clock.
 */
export class CommandCoalescer {
  private readonly keys = new Map<string, KeyState>();
  private readonly dispatch: CommandCoalescerOptions["dispatch"];
  private readonly onCoalesced: (coalesced: CoalescedCommand) => void;
  private readonly claimWindowMs: number;
  private readonly releaseWindowMs: number;
  private readonly now: () => number;
  private readonly scheduler: Scheduler | undefined;

  constructor(options: CommandCoalescerOptions) {
    this.dispatch = options.dispatch;
    this.onCoalesced = options.onCoalesced ?? (() => {});
    this.claimWindowMs = options.claimWindowMs ?? DEFAULT_CLAIM_WINDOW_MS;
    this.releaseWindowMs = options.releaseWindowMs ?? DEFAULT_RELEASE_WINDOW_MS;
    this.now = options.now ?? (() => Date.now());
    this.scheduler = options.scheduler;
  }

  /**
   * The window that applies after dispatching `kind`.
   *
   * Keyed on what was *last sent*, not on what is arriving: the window exists
   * to cover the settle time of the command already executing on the device.
   */
  private windowFor(kind: CommandKind): number {
    return kind === "claim" ? this.claimWindowMs : this.releaseWindowMs;
  }

  private keyOf(account: string, node: string, resource: string): string {
    // Node ids are UUIDs, resource types are a closed set of lowercase words,
    // and account ids carry no colons, so this delimiter cannot be ambiguous
    // without escaping.
    return `${account}::${node}::${resource}`;
  }

  /**
   * Submits a command for this key, dispatching it now or holding it.
   *
   * A release always dispatches now. A claim dispatches now unless this node
   * was commanded within the window, in which case it is held and collapsed
   * with anything else that arrives before the window closes.
   *
   * Call this for a state *transition*. A re-assertion to a node that has lost
   * its own copy of the state must not come through here - see
   * {@link dispatchImmediately}.
   */
  submit(account: string, node: string, resource: string, kind: CommandKind): void {
    const key = this.keyOf(account, node, resource);
    const state = this.keys.get(key);
    const at = this.now();

    const windowElapsed =
      state === undefined || at - state.lastDispatchedAt >= this.windowFor(state.lastDispatched);

    // A release is never held - see the class kdoc. It also cancels a queued
    // claim, because "let go" is the newer intent and a claim arriving after it
    // would undo it.
    if (kind === "release" || windowElapsed) {
      if (state?.pending !== undefined) {
        this.onCoalesced({
          account,
          node,
          resource,
          dropped: state.pending,
          reason: "superseded_by_newer_command",
        });
      }
      this.clearTimer(state);
      this.keys.set(key, { lastDispatched: kind, lastDispatchedAt: at });
      this.dispatch(account, node, resource, kind);
      return;
    }

    // A claim, inside the window. Anything already queued is stale now, whether
    // or not it says the same thing - either way it is not what gets sent.
    if (state.pending !== undefined) {
      this.onCoalesced({
        account,
        node,
        resource,
        dropped: state.pending,
        reason: "superseded_by_newer_command",
      });
    }
    state.pending = kind;

    if (state.timer === undefined) {
      const remaining = state.lastDispatchedAt + this.windowFor(state.lastDispatched) - at;
      // Math.max: a clock that jumped backwards, or a submit landing exactly on
      // the boundary, must not schedule a negative delay.
      state.timer = this.setTimeout(() => {
        state.timer = undefined;
        this.flush(account, node, resource, key);
      }, Math.max(remaining, 0));
    }
  }

  /**
   * Publishes now, bypassing coalescing entirely, and resets the window.
   *
   * For the re-assert in `relay-service.ts`'s registration handler, and this
   * distinction is load-bearing rather than a convenience. That command goes to
   * a node that has **restarted and lost its own state**, so it is not a
   * transition the relay can coalesce away: if a CLAIM had been dispatched to
   * that node moments before it restarted, `submit` would see a pending claim
   * matching the last dispatched claim, conclude there was nothing to send, and
   * leave the relay believing the node holds the route while the node itself
   * believed it held nothing. Routing it here is what stops coalescing turning
   * a restart into a silent desync.
   */
  dispatchImmediately(account: string, node: string, resource: string, kind: CommandKind): void {
    const key = this.keyOf(account, node, resource);
    const state = this.keys.get(key);
    if (state?.pending !== undefined) {
      // A queued transition is stale now: this re-assert is the newer truth.
      this.onCoalesced({
        account,
        node,
        resource,
        dropped: state.pending,
        reason: "superseded_by_newer_command",
      });
    }
    this.clearTimer(state);
    this.keys.set(key, { lastDispatched: kind, lastDispatchedAt: this.now() });
    this.dispatch(account, node, resource, kind);
  }

  /** Drops every pending command and timer - for `RelayService.stop()`. */
  stop(): void {
    for (const state of this.keys.values()) this.clearTimer(state);
    this.keys.clear();
  }

  private flush(account: string, node: string, resource: string, key: string): void {
    const state = this.keys.get(key);
    if (state?.pending === undefined) return;

    const pending = state.pending;
    state.pending = undefined;

    if (pending === state.lastDispatched) {
      // The intent collapsed back to what this node was already told. Sending
      // it again would be a no-op the node would have to absorb, so it is
      // dropped - and reported, because "a burst cancelled itself out" is the
      // interesting case, not a silent one.
      this.onCoalesced({ account, node, resource, dropped: pending, reason: "already_in_target_state" });
      return;
    }

    state.lastDispatched = pending;
    state.lastDispatchedAt = this.now();
    this.dispatch(account, node, resource, pending);
  }

  private setTimeout(callback: () => void, ms: number): unknown {
    if (this.scheduler) return this.scheduler.setTimeout(callback, ms);
    return setTimeout(callback, ms);
  }

  private clearTimer(state: KeyState | undefined): void {
    if (state?.timer === undefined) return;
    if (this.scheduler) this.scheduler.clearTimeout(state.timer);
    else clearTimeout(state.timer as ReturnType<typeof setTimeout>);
    state.timer = undefined;
  }
}
