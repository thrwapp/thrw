import { describe, expect, it } from "vitest";
import { relayHostedPackageName } from "../src/index";

describe("@thrw/relay-hosted", () => {
  it("exposes its package name as a placeholder export", () => {
    expect(relayHostedPackageName).toBe("@thrw/relay-hosted");
  });
});
