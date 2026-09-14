import { describe, expect, it } from "vitest";
import { accountsPackageName } from "../src/index";

describe("@thrw/accounts", () => {
  it("exposes its package name as a placeholder export", () => {
    expect(accountsPackageName).toBe("@thrw/accounts");
  });
});
