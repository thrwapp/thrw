import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { beforeAll, describe, expect, it } from "vitest";

const siteRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const builtPage = join(siteRoot, "dist", "privacy", "index.html");
const builtIndex = join(siteRoot, "dist", "index.html");

// This page is a hard prerequisite for both store submissions (#132): App
// Store Connect and Play Console each require a reachable privacy policy
// URL. These assertions guard the claims the Play Data Safety declaration
// is asserted against — if the adapter's behaviour changes such that one of
// these is no longer true, this test failing is the intended signal to
// update both the page and that declaration, not to delete the assertion.
let html: string;

describe("privacy policy page", () => {
  beforeAll(() => {
    if (!existsSync(builtPage)) {
      throw new Error(
        `${builtPage} is missing — run \`pnpm build\` in content/site first.`,
      );
    }
    html = readFileSync(builtPage, "utf8");
  });

  it("is reachable at /privacy", () => {
    expect(existsSync(builtPage)).toBe(true);
  });

  it("states the audio, contacts, and notification-content exclusions", () => {
    expect(html).toContain("No audio, ever.");
    expect(html).toContain("No phone numbers, contacts, or call history.");
    expect(html).toContain("No notification content.");
  });

  it("names the operating entity and a contact address", () => {
    expect(html).toContain("Barhatch Limited");
    expect(html).toContain("privacy@thrw.app");
  });

  it("is linked from the landing page footer", () => {
    const index = readFileSync(builtIndex, "utf8");
    expect(index).toMatch(/<a[^>]*href="\/privacy"[^>]*>Privacy<\/a>/);
  });
});
