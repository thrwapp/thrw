import { describe, expect, it } from "vitest";
import { PriorityEngine } from "../src/index.js";

/**
 * #236 - reproduction of the production oscillation.
 *
 * The relay logs for 2026-09-21T16:00Z -> 2026-09-22T01:20Z show the
 * headset alternating Mac <-> Pixel roughly every 90-120s for nine and a
 * half hours, unattended, with every accompanying `route_drift` of the
 * same shape (relay believes node holds, node reports it does not).
 *
 * These tests establish *what the engine does* given a particular
 * sequence of registrations. They deliberately do not assert that the
 * engine is wrong - `reconcileSignals` behaves exactly as
 * `index.test.ts`'s "lets a genuinely new signal win the tie-break"
 * specifies. The point is to show how little it takes to turn that
 * correct rule into an unbounded loop, and therefore where to look.
 */
describe("#236 holder oscillation", () => {
  const REGISTRATION_INTERVAL_MS = 120_000;

  /** One periodic registration: the node reports its active set. */
  type Registration = { node: string; active: readonly ("media" | "call" | "voip" | "manual_claim")[] };

  /** Runs registrations in order, recording the holder after each. */
  function holdersOver(engine: PriorityEngine, regs: readonly Registration[]): string[] {
    const holders: string[] = [];
    for (const { node, active } of regs) {
      engine.reconcileSignals(node, active);
      holders.push(engine.currentHolder() ?? "none");
    }
    return holders;
  }

  it("is stable when both nodes report the same set every time", () => {
    // The baseline the production logs contradict. Two devices both
    // playing, both re-registering forever, nothing else happening:
    // whoever started later keeps it, and no amount of re-registering
    // moves it. This is the guard at src/index.ts:198 working.
    const engine = new PriorityEngine();
    engine.recordEvent("mac", "media");
    engine.recordEvent("pixel", "media");
    expect(engine.currentHolder()).toBe("pixel");

    const regs: Registration[] = [];
    for (let i = 0; i < 10; i++) {
      regs.push({ node: i % 2 === 0 ? "mac" : "pixel", active: ["media"] });
    }

    expect(new Set(holdersOver(engine, regs))).toEqual(new Set(["pixel"]));
  });

  it("oscillates once each node's reported set drops and regains the signal", () => {
    // The same two nodes, both still genuinely playing the whole time -
    // but each one's *reported* set momentarily loses `media` and then
    // reports it again on the following registration.
    //
    // Nothing here is a relay bug: each re-report looks exactly like a
    // newly-started trigger, which is precisely what
    // `reconcileSignals` is specified to reward. The defect is upstream,
    // in whatever makes a continuously-playing node report a gap.
    const engine = new PriorityEngine();
    engine.recordEvent("mac", "media");
    engine.recordEvent("pixel", "media");

    // Offset by half an interval, as two independently-phased 120s
    // timers would be.
    const regs: Registration[] = [
      { node: "mac", active: [] },
      { node: "pixel", active: [] },
      { node: "mac", active: ["media"] },
      { node: "pixel", active: ["media"] },
      { node: "mac", active: [] },
      { node: "pixel", active: [] },
      { node: "mac", active: ["media"] },
      { node: "pixel", active: ["media"] },
    ];

    const holders = holdersOver(engine, regs);

    // Every time a node re-reports, it takes the headset. Over four
    // cycles that is four handoffs - matching the observed ~30/hour at a
    // 120s cadence across two nodes.
    expect(holders).toEqual([
      "pixel", // mac dropped; pixel still has its original media
      "pixel", // both now empty - rule 5 fallback keeps pixel
      "mac", // mac re-reports: newest start, takes it
      "pixel", // pixel re-reports: newer still, takes it back
      "pixel",
      "pixel",
      "mac",
      "pixel",
    ]);

    const handoffs = holders.filter((h, i) => i > 0 && h !== holders[i - 1]).length;
    expect(handoffs).toBeGreaterThanOrEqual(4);
  });

  it("a single node reporting a gap is enough to lose and retake the headset", () => {
    // The minimal case, isolated: one gap, one steal. This is the unit
    // the loop above is built from.
    const engine = new PriorityEngine();
    engine.recordEvent("mac", "media");
    engine.recordEvent("pixel", "media");
    expect(engine.currentHolder()).toBe("pixel");

    engine.reconcileSignals("mac", []);
    engine.reconcileSignals("mac", ["media"]);

    expect(engine.currentHolder()).toBe("mac");
  });

  it("documents the registration cadence the production timestamps match", () => {
    // Median gap between holder_change lines was 107s, pairs clustered
    // 90-120s. Recorded here so the next person does not have to
    // re-derive where that number comes from.
    expect(REGISTRATION_INTERVAL_MS).toBe(120_000);
  });
});
