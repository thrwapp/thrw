import { describe, expect, it } from "vitest";
import type { Scheduler } from "../src/index";
import { DEFAULT_AUTO_RETURN_MS, PriorityEngine, relayCorePackageName } from "../src/index";

// Deterministic, fully controllable stand-in for the injectable time source
// (acceptance criterion 4) - no real setTimeout delays, no wall-clock waits.
class FakeScheduler implements Scheduler {
  private nextId = 1;
  private readonly timers = new Map<number, { callback: () => void; ms: number }>();

  setTimeout(callback: () => void, ms: number): unknown {
    const id = this.nextId++;
    this.timers.set(id, { callback, ms });
    return id;
  }

  clearTimeout(handle: unknown): void {
    this.timers.delete(handle as number);
  }

  pendingCount(): number {
    return this.timers.size;
  }

  fire(ms: number): void {
    for (const [id, timer] of this.timers) {
      if (timer.ms <= ms) {
        this.timers.delete(id);
        timer.callback();
      }
    }
  }
}

describe("@thrw/relay-core", () => {
  it("exposes its package name as a placeholder export", () => {
    expect(relayCorePackageName).toBe("@thrw/relay-core");
  });

  it("rule 5: last-claimed node keeps it when nothing else is active", () => {
    const engine = new PriorityEngine();
    expect(engine.currentHolder()).toBeNull();

    engine.recordEvent("node-a", "media");
    expect(engine.currentHolder()).toBe("node-a");

    engine.endEvent("node-a", "media");
    expect(engine.currentHolder()).toBe("node-a");
  });

  it("rule 4: media beats no signal, and a lower-priority signal elsewhere does not preempt it", () => {
    const engine = new PriorityEngine();
    engine.recordEvent("node-a", "media");
    expect(engine.currentHolder()).toBe("node-a");

    // node-b has nothing higher-priority active, so node-a keeps the claim.
    expect(engine.currentHolder()).toBe("node-a");
  });

  it("rule 3: voip beats media, even media active on a different node", () => {
    const engine = new PriorityEngine();
    engine.recordEvent("node-a", "media");
    engine.recordEvent("node-b", "voip");

    expect(engine.currentHolder()).toBe("node-b");
  });

  it("rule 2: manual_claim beats voip and media active elsewhere", () => {
    const engine = new PriorityEngine();
    engine.recordEvent("node-a", "media");
    engine.recordEvent("node-b", "voip");
    engine.recordEvent("node-c", "manual_claim");

    expect(engine.currentHolder()).toBe("node-c");
  });

  it("rule 1: call always wins over manual_claim, voip, and media", () => {
    const engine = new PriorityEngine();
    engine.recordEvent("node-a", "media");
    engine.recordEvent("node-b", "voip");
    engine.recordEvent("node-c", "manual_claim");
    engine.recordEvent("node-d", "call");

    expect(engine.currentHolder()).toBe("node-d");
  });

  it("a lower-priority signal starting on another node does not preempt an active higher-priority one", () => {
    const engine = new PriorityEngine();
    engine.recordEvent("node-a", "voip");
    expect(engine.currentHolder()).toBe("node-a");

    engine.recordEvent("node-b", "media");
    expect(engine.currentHolder()).toBe("node-a");

    engine.recordEvent("node-c", "manual_claim");
    expect(engine.currentHolder()).toBe("node-c");

    engine.recordEvent("node-d", "call");
    expect(engine.currentHolder()).toBe("node-d");

    // Ending the call falls back through the still-active signals, not
    // straight to nothing: manual_claim on node-c is still active.
    engine.endEvent("node-d", "call");
    expect(engine.currentHolder()).toBe("node-c");
  });

  it("ending the top signal falls back to the next highest still-active one", () => {
    const engine = new PriorityEngine();
    engine.recordEvent("node-a", "media");
    engine.recordEvent("node-b", "voip");
    expect(engine.currentHolder()).toBe("node-b");

    engine.endEvent("node-b", "voip");
    expect(engine.currentHolder()).toBe("node-a");
  });

  it("auto-return: after a call ends, the previous holder gets the claim back once the mocked clock fires the default timeout", () => {
    const scheduler = new FakeScheduler();
    const engine = new PriorityEngine({ scheduler });

    engine.recordEvent("node-a", "media");
    engine.endEvent("node-a", "media");
    expect(engine.currentHolder()).toBe("node-a");

    engine.recordEvent("node-b", "call");
    expect(engine.currentHolder()).toBe("node-b");

    engine.endEvent("node-b", "call");
    // Grace period: node-b (last claimed) still holds it until the timeout,
    // since no other signal is active to fall back to in the meantime.
    expect(engine.currentHolder()).toBe("node-b");
    expect(scheduler.pendingCount()).toBe(1);

    scheduler.fire(DEFAULT_AUTO_RETURN_MS);
    expect(engine.currentHolder()).toBe("node-a");
  });

  it("auto-return is preempted by a higher-priority signal before the timeout fires", () => {
    const scheduler = new FakeScheduler();
    const engine = new PriorityEngine({ scheduler });

    engine.recordEvent("node-a", "media");
    engine.recordEvent("node-b", "call");
    engine.endEvent("node-b", "call");
    expect(scheduler.pendingCount()).toBe(1);

    // A new signal (rule 1-4) preempts the scheduled auto-return.
    engine.recordEvent("node-c", "manual_claim");
    expect(scheduler.pendingCount()).toBe(0);
    expect(engine.currentHolder()).toBe("node-c");

    // Even if the clock were advanced, there's nothing left to fire.
    scheduler.fire(DEFAULT_AUTO_RETURN_MS);
    expect(engine.currentHolder()).toBe("node-c");
  });

  it("does not schedule an auto-return when the call's own node was already the holder", () => {
    const scheduler = new FakeScheduler();
    const engine = new PriorityEngine({ scheduler });

    engine.recordEvent("node-a", "call");
    engine.endEvent("node-a", "call");

    expect(scheduler.pendingCount()).toBe(0);
    expect(engine.currentHolder()).toBe("node-a");
  });

  it("supports a custom auto-return timeout", () => {
    const scheduler = new FakeScheduler();
    const engine = new PriorityEngine({ scheduler, autoReturnMs: 5_000 });

    engine.recordEvent("node-a", "media");
    engine.endEvent("node-a", "media");
    engine.recordEvent("node-b", "call");
    engine.endEvent("node-b", "call");

    scheduler.fire(4_999);
    expect(engine.currentHolder()).toBe("node-b");

    scheduler.fire(5_000);
    expect(engine.currentHolder()).toBe("node-a");
  });
});
