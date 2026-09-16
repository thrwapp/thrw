import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { beforeAll, describe, expect, it } from "vitest";

const siteRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const builtPage = join(siteRoot, "dist", "index.html");

// The copy below is duplicated deliberately: these are the literal strings
// from issue #34's criterion 3, so the test fails if the page copy is ever
// reworded rather than tracking the page's own source.
const HERO_HEADLINE = "One headset. Every device you actually use.";
const CTA_TEXT = "Join the waitlist";
const BODY_PARAGRAPH_1 =
  "Apple's own device-switching only works between Apple devices signed into the same Apple ID — and even then, it's inconsistently reliable. Add an Android phone, a Windows laptop, or Linux to the mix and you get no automatic handoff at all. thrw runs a small adapter on each of your devices and switches your headset to whichever one needs it — a call, a meeting starting, playback beginning — across ecosystems, without you touching a settings menu.";
const BODY_PARAGRAPH_2 =
  "Switching is a real disconnect-and-reconnect, not an instant swap — so it takes a few real seconds, not zero. We're not going to pretend otherwise, or promise a number until we've measured it against real hardware.";

let html: string;

describe("rendered landing page", () => {
  beforeAll(() => {
    // `turbo.json` in this package makes `test` depend on `build`, so the
    // built page is present whenever this runs under turbo. Building here
    // instead would race the `build` task over `dist/`.
    if (!existsSync(builtPage)) {
      throw new Error(
        `${builtPage} is missing — run \`pnpm build\` in content/site first.`,
      );
    }
    html = readFileSync(builtPage, "utf8");
  });

  it("contains the hero headline", () => {
    expect(html).toContain(HERO_HEADLINE);
  });

  it("contains the call-to-action text", () => {
    expect(html).toContain(CTA_TEXT);
  });

  it("renders the call-to-action as a real link", () => {
    expect(html).toMatch(/<a[^>]*>Join the waitlist<\/a>/);
  });

  it("contains both body paragraphs verbatim", () => {
    expect(html).toContain(BODY_PARAGRAPH_1);
    expect(html).toContain(BODY_PARAGRAPH_2);
  });
});
