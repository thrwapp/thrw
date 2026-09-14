import { describe, expect, it } from "vitest";
import { relayCorePackageName } from "../src/index";

describe("@thrw/relay-core", () => {
  it("exposes its package name as a placeholder export", () => {
    expect(relayCorePackageName).toBe("@thrw/relay-core");
  });
});
