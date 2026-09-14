import { describe, expect, it } from "vitest";
import { aiEnginePackageName } from "../src/index";

describe("@thrw/ai-engine", () => {
  it("exposes its package name as a placeholder export", () => {
    expect(aiEnginePackageName).toBe("@thrw/ai-engine");
  });
});
