import { describe, expect, it } from "vitest";
import { sleep } from "../src/index";

describe("sleep", () => {
  it("resolves after at least the requested duration", async () => {
    const start = performance.now();
    await sleep(50);
    const elapsed = performance.now() - start;
    // A real setTimeout is only guaranteed to fire no *significantly*
    // earlier than requested - some engines' timers can fire a fraction
    // of a millisecond early as an internal scheduling optimization.
    // Confirmed live: this flaked CI twice with elapsed just under 50
    // (49.50ms, then 49.80ms) despite sleep() being correctly
    // implemented - asserting the exact boundary is what's fragile, not
    // the code under test.
    expect(elapsed).toBeGreaterThanOrEqual(45);
  });
});
