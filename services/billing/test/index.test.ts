import { describe, expect, it } from "vitest";
import { billingPackageName } from "../src/index";

describe("@thrw/billing", () => {
  it("exposes its package name as a placeholder export", () => {
    expect(billingPackageName).toBe("@thrw/billing");
  });
});
