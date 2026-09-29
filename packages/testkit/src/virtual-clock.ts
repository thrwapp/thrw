import type { Scheduler } from "@thrw/relay-core";

/**
 * Time that only moves when told to (#320).
 *
 * Implements `relay-core`'s existing {@link Scheduler} — the seam
 * `PriorityEngine`, `CommandCoalescer` and `RelayService` already take a
 * scheduler through — and adds a {@link now} for the wall-clock reads
 * `RelayService` makes for heartbeat staleness.
 *
 * This replaces the three near-identical `FakeScheduler` classes the repo
 * had accumulated (`relay-core`'s `index.test.ts` and
 * `handoff-integration.test.ts`, `relay-hosted`'s `relay-service.test.ts`,
 * whose own comment notes they were "duplicated rather than shared").
 * Each had slightly different `fire` semantics, and one of those
 * differences was load-bearing: `relay-service.test.ts` had to snapshot
 * the due set before firing because the heartbeat sweep **reschedules
 * itself**, so a live-iteration version either skipped the new timer or
 * looped forever. {@link advance} below handles that case by
 * construction rather than by each caller remembering to.
 *
 * ## Why `advance` is a loop over due timers, not a single pass
 *
 * A timer's callback can schedule another timer, and that new timer may
 * itself be due before the target time (the heartbeat sweep at 15s
 * intervals, advanced by a minute, must fire four times). So `advance`
 * repeatedly takes the *earliest* due timer, moves `now` to exactly that
 * timer's deadline, and fires it — which means a callback observing
 * {@link now} sees the time its own deadline fell at, not the target.
 * That ordering is what makes a scenario's assertions about *when*
 * something happened meaningful.
 */
export class VirtualClock implements Scheduler {
  private currentMs: number;
  private nextId = 1;
  private readonly timers = new Map<number, { callback: () => void; dueAt: number }>();

  /**
   * @param startMs Deliberately non-zero by default. A clock starting at
   *   0 makes "unset" and "the beginning of time" indistinguishable, and
   *   `RelayService` stores `lastHeartbeatAt` timestamps that are compared
   *   against `now()` — a zero origin lets a missing entry look like a
   *   very old one.
   */
  constructor(startMs = 1_000_000) {
    this.currentMs = startMs;
  }

  /** Milliseconds since this clock's origin. Matches `Date.now()`'s shape, not its value. */
  now(): number {
    return this.currentMs;
  }

  setTimeout(callback: () => void, ms: number): unknown {
    const id = this.nextId++;
    this.timers.set(id, { callback, dueAt: this.currentMs + ms });
    return id;
  }

  clearTimeout(handle: unknown): void {
    this.timers.delete(handle as number);
  }

  /** How many timers are still scheduled — the assertion `handoff-integration` makes about the auto-return timer. */
  pendingCount(): number {
    return this.timers.size;
  }

  /**
   * Moves time forward by `ms`, firing every timer that comes due, in
   * deadline order, including timers scheduled by the callbacks this
   * fires.
   *
   * Guarded against a callback that reschedules itself with a zero or
   * negative delay, which would otherwise spin forever at one instant:
   * such a timer is due immediately and re-due immediately.
   *
   * The guard counts firings **at one instant** and resets whenever time
   * moves, rather than counting firings per call. That distinction
   * matters: a legitimate 14-day advance fires the 15s heartbeat sweep
   * ~80,600 times, so any per-call ceiling low enough to catch a spin
   * quickly would also reject the soak scenarios v1's exit criteria are
   * built on. Non-advancing time is the actual symptom; the total is not.
   */
  advance(ms: number): void {
    const target = this.currentMs + ms;
    let firedAtInstant = 0;
    let lastInstant = this.currentMs;

    for (;;) {
      const due = this.earliestDueBy(target);
      if (due === null) break;

      const [id, timer] = due;
      this.timers.delete(id);

      if (timer.dueAt === lastInstant) {
        if (++firedAtInstant > VirtualClock.maxFiringsPerInstant) {
          throw new Error(
            `VirtualClock.advance fired ${firedAtInstant} timers at ${lastInstant}ms without ` +
              "time moving — a callback is almost certainly rescheduling itself with a " +
              "non-positive delay",
          );
        }
      } else {
        firedAtInstant = 1;
        lastInstant = timer.dueAt;
      }

      // Before the callback, so anything it reads from `now()` - or
      // schedules relative to it - is anchored at its own deadline.
      this.currentMs = timer.dueAt;
      timer.callback();
    }

    // Only after the queue is drained, so a timer due at exactly `target`
    // has already run and `now()` is not left behind its own timers.
    this.currentMs = target;
  }

  /**
   * Advances to exactly the moment the next timer is due, whenever that
   * is. Lets a scenario say "let the coalescing window close" without
   * hard-coding the window, which would duplicate the constant under test.
   */
  advanceToNextTimer(): void {
    let earliest: number | null = null;
    for (const { dueAt } of this.timers.values()) {
      if (earliest === null || dueAt < earliest) earliest = dueAt;
    }
    if (earliest === null) return;
    this.advance(earliest - this.currentMs);
  }

  private earliestDueBy(target: number): [number, { callback: () => void; dueAt: number }] | null {
    let best: [number, { callback: () => void; dueAt: number }] | null = null;
    for (const entry of this.timers) {
      const [id, timer] = entry;
      if (timer.dueAt > target) continue;
      // Ties break on insertion order: `Map` iterates in insertion order
      // and ids ascend, so `<` rather than `<=` keeps the earlier-scheduled
      // timer of two with the same deadline.
      if (best === null || timer.dueAt < best[1].dueAt) best = [id, timer];
    }
    return best;
  }

  /**
   * Generous, because a single instant can legitimately have many timers
   * due at once (every node in a scenario reporting at the same moment).
   * Low enough that a genuine spin fails in well under a second.
   */
  private static readonly maxFiringsPerInstant = 10_000;
}
