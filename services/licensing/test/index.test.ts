import { describe, expect, it } from "vitest";
import { licensingPackageName } from "../src/index";

describe("@thrw/licensing", () => {
  it("exposes its package name as a placeholder export", () => {
    expect(licensingPackageName).toBe("@thrw/licensing");
  });
});
