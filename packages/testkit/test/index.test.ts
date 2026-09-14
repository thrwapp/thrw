import { describe, expect, it } from "vitest";
import { testkitPackageName } from "../src/index";

describe("@thrw/testkit", () => {
  it("exposes its package name as a placeholder export", () => {
    expect(testkitPackageName).toBe("@thrw/testkit");
  });
});
