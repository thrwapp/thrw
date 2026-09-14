import { describe, expect, it } from "vitest";
import { telemetryPackageName } from "../src/index";

describe("@thrw/telemetry", () => {
  it("exposes its package name as a placeholder export", () => {
    expect(telemetryPackageName).toBe("@thrw/telemetry");
  });
});
