import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { runScenario } from "../src/scenario/runner.js";
import type { Scenario } from "../src/scenario/types.js";

const SCENARIO_DIR = join(import.meta.dirname, "..", "scenarios");

function load(): Scenario[] {
  return readdirSync(SCENARIO_DIR)
    .filter((f) => f.endsWith(".json"))
    .sort()
    .map((f) => JSON.parse(readFileSync(join(SCENARIO_DIR, f), "utf8")) as Scenario);
}

/**
 * The scenario suite (#329).
 *
 * ## Expected-fail is not skip (criterion 5)
 *
 * A scenario known to fail on the current build carries `expectedFail`
 * with its reason, and this suite asserts it **does** fail. So the
 * backlog cannot rot two ways: a regression in a passing scenario fails
 * normally, and a marked scenario that starts passing *also* fails,
 * forcing the marker to be removed deliberately rather than left to
 * mislead.
 *
 * Skipping would do neither.
 */
describe("scenarios", () => {
  const scenarios = load();

  it("found scenario files to run", () => {
    expect(scenarios.length).toBeGreaterThan(0);
  });

  for (const scenario of scenarios) {
    const label = `${scenario.id} — ${scenario.title}`;

    if (scenario.expectedFail) {
      it(`${label} [expected fail: ${scenario.expectedFail}]`, () => {
        const result = runScenario(scenario);
        expect(
          result.failures.length,
          `${scenario.id} is marked expectedFail (${scenario.expectedFail}) but passed. ` +
            `If it is genuinely fixed, remove the marker in the same change that fixed it.`,
        ).toBeGreaterThan(0);
      });
      continue;
    }

    it(label, () => {
      const result = runScenario(scenario);
      expect(result.failures, result.failures.join("; ")).toEqual([]);
    });
  }

  /** Criterion 7: the whole suite on a virtual clock, no real sleeps. */
  it("runs a five-minute scenario in milliseconds of real time", () => {
    const n5 = scenarios.find((s) => s.id === "N5");
    expect(n5).toBeDefined();
    const startedAt = Date.now();
    runScenario(n5!);
    expect(Date.now() - startedAt).toBeLessThan(2000);
  });
});
