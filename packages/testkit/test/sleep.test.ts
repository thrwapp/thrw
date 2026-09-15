import { describe, expect, it } from "vitest";
import { sleep } from "../src/index";

describe("sleep", () => {
  it("resolves after at least the requested duration", async () => {
    const start = performance.now();
    await sleep(50);
    const elapsed = performance.now() - start;
    expect(elapsed).toBeGreaterThanOrEqual(50);
  });
});
