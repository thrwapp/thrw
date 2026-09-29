import { describe, expect, it } from "vitest";
import { VirtualClock } from "../src/virtual-clock.js";

describe("VirtualClock", () => {
  it("does not move on its own", () => {
    const clock = new VirtualClock(1000);
    expect(clock.now()).toBe(1000);
    let fired = false;
    clock.setTimeout(() => {
      fired = true;
    }, 50);
    expect(clock.now()).toBe(1000);
    expect(fired).toBe(false);
  });

  it("fires a timer once its deadline is reached, and only then", () => {
    const clock = new VirtualClock(0);
    const order: string[] = [];
    clock.setTimeout(() => order.push("at-100"), 100);

    clock.advance(99);
    expect(order).toEqual([]);

    clock.advance(1);
    expect(order).toEqual(["at-100"]);
    expect(clock.now()).toBe(100);
  });

  it("fires timers in deadline order, not scheduling order", () => {
    const clock = new VirtualClock(0);
    const order: string[] = [];
    clock.setTimeout(() => order.push("late"), 90);
    clock.setTimeout(() => order.push("early"), 10);
    clock.setTimeout(() => order.push("middle"), 50);

    clock.advance(100);
    expect(order).toEqual(["early", "middle", "late"]);
  });

  it("breaks a deadline tie on scheduling order", () => {
    const clock = new VirtualClock(0);
    const order: string[] = [];
    clock.setTimeout(() => order.push("first"), 10);
    clock.setTimeout(() => order.push("second"), 10);

    clock.advance(10);
    expect(order).toEqual(["first", "second"]);
  });

  /**
   * A callback observing `now()` must see its own deadline, not the
   * target of the `advance` that happened to run it. Scenarios assert on
   * *when* a command was dispatched, and `RelayService` stamps heartbeat
   * timestamps from `now()` — if every timer in one advance saw the same
   * final time, a 90s advance would make four heartbeat sweeps look
   * simultaneous.
   */
  it("anchors now() at each timer's own deadline while it runs", () => {
    const clock = new VirtualClock(0);
    const seen: number[] = [];
    clock.setTimeout(() => seen.push(clock.now()), 10);
    clock.setTimeout(() => seen.push(clock.now()), 70);

    clock.advance(1000);
    expect(seen).toEqual([10, 70]);
    expect(clock.now()).toBe(1000);
  });

  it("clears a timer so it never fires", () => {
    const clock = new VirtualClock(0);
    let fired = false;
    const handle = clock.setTimeout(() => {
      fired = true;
    }, 10);
    clock.clearTimeout(handle);

    clock.advance(100);
    expect(fired).toBe(false);
    expect(clock.pendingCount()).toBe(0);
  });

  /**
   * The case that made the repo's three hand-written `FakeScheduler`s
   * differ from each other. `RelayService`'s heartbeat sweep reschedules
   * itself at the end of each run, so a naive implementation either
   * iterates a collection being mutated, fires the newly-added timer in
   * the same pass when it is not yet due, or loops forever.
   *
   * One minute at a 15s interval is four sweeps, and the fifth must be
   * left pending rather than fired.
   */
  it("fires a self-rescheduling timer exactly as often as its interval allows", () => {
    const clock = new VirtualClock(0);
    const firedAt: number[] = [];

    const tick = (): void => {
      firedAt.push(clock.now());
      clock.setTimeout(tick, 15_000);
    };
    clock.setTimeout(tick, 15_000);

    clock.advance(60_000);
    expect(firedAt).toEqual([15_000, 30_000, 45_000, 60_000]);
    expect(clock.pendingCount()).toBe(1);
  });

  it("fires a timer scheduled by another timer when it comes due in the same advance", () => {
    const clock = new VirtualClock(0);
    const order: string[] = [];
    clock.setTimeout(() => {
      order.push("outer");
      clock.setTimeout(() => order.push("inner"), 5);
    }, 10);

    clock.advance(100);
    expect(order).toEqual(["outer", "inner"]);
  });

  /**
   * A zero-delay timer scheduling another zero-delay timer never advances
   * time, so it is due forever. That has to fail loudly as a test rather
   * than hang CI — the bus schedules delivery at zero delay, so this is a
   * mistake a scenario can actually make.
   */
  it("throws rather than spinning when a callback reschedules itself at zero delay", () => {
    const clock = new VirtualClock(0);
    const spin = (): void => {
      clock.setTimeout(spin, 0);
    };
    clock.setTimeout(spin, 0);

    expect(() => clock.advance(1)).toThrow(/rescheduling itself with a non-positive delay/);
  });

  /**
   * The spin guard must key on time not moving, not on how many timers
   * fired. A 14-day soak at `RelayService`'s 15s heartbeat sweep is ~80,600
   * legitimate firings, and v1's exit criteria require exactly that run —
   * so a per-call ceiling low enough to catch a spin promptly would reject
   * the thing the clock exists for.
   */
  it("does not mistake a long soak for a spin", () => {
    const clock = new VirtualClock(0);
    let firings = 0;
    const sweep = (): void => {
      firings += 1;
      clock.setTimeout(sweep, 15_000);
    };
    clock.setTimeout(sweep, 15_000);

    const thirtyDays = 30 * 24 * 60 * 60 * 1000;
    expect(() => clock.advance(thirtyDays)).not.toThrow();
    expect(firings).toBe(thirtyDays / 15_000);
  });

  describe("advanceToNextTimer", () => {
    /**
     * Lets a scenario say "let the coalescing window close" without
     * naming the window's length, which would duplicate the very constant
     * under test — and would then keep passing if that constant changed.
     */
    it("advances to exactly the next deadline", () => {
      const clock = new VirtualClock(0);
      const firedAt: number[] = [];
      clock.setTimeout(() => firedAt.push(clock.now()), 3000);
      clock.setTimeout(() => firedAt.push(clock.now()), 6000);

      clock.advanceToNextTimer();
      expect(clock.now()).toBe(3000);
      expect(firedAt).toEqual([3000]);

      clock.advanceToNextTimer();
      expect(clock.now()).toBe(6000);
      expect(firedAt).toEqual([3000, 6000]);
    });

    it("is a no-op when nothing is scheduled", () => {
      const clock = new VirtualClock(500);
      clock.advanceToNextTimer();
      expect(clock.now()).toBe(500);
    });
  });

  /**
   * A zero origin makes "never set" and "the beginning of time"
   * indistinguishable, and `RelayService` compares stored
   * `lastHeartbeatAt` values against `now()` — a missing entry would look
   * like a very old one.
   */
  it("starts well away from zero by default", () => {
    expect(new VirtualClock().now()).toBeGreaterThan(0);
  });
});
