import { describe, expect, it } from "vitest";
import { protocolPackageName } from "../src/index";

describe("@thrw/protocol", () => {
  it("exposes its package name as a placeholder export", () => {
    expect(protocolPackageName).toBe("@thrw/protocol");
  });
});
