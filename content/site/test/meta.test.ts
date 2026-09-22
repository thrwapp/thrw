import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { beforeAll, describe, expect, it } from "vitest";

// The metadata asserted here is the difference between a shared thrw link
// rendering as a title card with an image and rendering as a bare URL, which
// is most of what a waitlist landing page is for. None of it is visible on
// the page itself, so nothing else would catch it silently regressing.
const siteRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const dist = join(siteRoot, "dist");
const ORIGIN = "https://thrw.app";

let index: string;
let privacy: string;

function metaContent(html: string, attr: "name" | "property", key: string) {
  // Astro emits attributes in source order, so the content attribute follows
  // the name/property one.
  const match = html.match(
    new RegExp(`<meta ${attr}="${key}" content="([^"]*)"`),
  );
  return match?.[1];
}

describe("built site metadata", () => {
  beforeAll(() => {
    const builtIndex = join(dist, "index.html");
    if (!existsSync(builtIndex)) {
      throw new Error(
        `${builtIndex} is missing — run \`pnpm build\` in content/site first.`,
      );
    }
    index = readFileSync(builtIndex, "utf8");
    privacy = readFileSync(join(dist, "privacy", "index.html"), "utf8");
  });

  it("gives every page a description and an absolute canonical URL", () => {
    expect(metaContent(index, "name", "description")).toBeTruthy();
    expect(metaContent(privacy, "name", "description")).toBeTruthy();
    // Trailing slash: Cloudflare Pages 308-redirects /privacy to /privacy/,
    // so the canonical has to name the URL that actually serves a 200.
    expect(index).toContain(`<link rel="canonical" href="${ORIGIN}/">`);
    expect(privacy).toContain(`<link rel="canonical" href="${ORIGIN}/privacy/">`);
  });

  it("carries Open Graph tags with an absolute image on both pages", () => {
    for (const html of [index, privacy]) {
      expect(metaContent(html, "property", "og:type")).toBe("website");
      expect(metaContent(html, "property", "og:title")).toBeTruthy();
      expect(metaContent(html, "property", "og:description")).toBeTruthy();
      // Relative og:image / og:url are rejected by Open Graph consumers.
      expect(metaContent(html, "property", "og:image")).toBe(`${ORIGIN}/og.png`);
      expect(metaContent(html, "property", "og:url")).toMatch(
        new RegExp(`^${ORIGIN}/`),
      );
      expect(metaContent(html, "property", "og:image:alt")).toBeTruthy();
    }
  });

  it("requests a large Twitter card", () => {
    expect(metaContent(index, "name", "twitter:card")).toBe(
      "summary_large_image",
    );
    expect(metaContent(index, "name", "twitter:image")).toBe(
      `${ORIGIN}/og.png`,
    );
  });

  it("ships the icons and the card image the markup points at", () => {
    expect(index).toContain('<link rel="icon" href="/favicon.svg"');
    expect(index).toContain('<link rel="apple-touch-icon" href="/apple-touch-icon.png">');
    expect(existsSync(join(dist, "favicon.svg"))).toBe(true);
    expect(existsSync(join(dist, "apple-touch-icon.png"))).toBe(true);
    expect(existsSync(join(dist, "og.png"))).toBe(true);
  });

  it("describes the FAQ as structured data matching the rendered questions", () => {
    const block = index.match(
      /<script type="application\/ld\+json">(.*?)<\/script>/s,
    );
    expect(block, "no JSON-LD block in the built page").toBeTruthy();

    const schema = JSON.parse(block![1]);
    expect(schema["@type"]).toBe("FAQPage");
    expect(schema.mainEntity.length).toBeGreaterThan(0);

    // The page markup and the structured data are generated from one array
    // in index.astro; this asserts they actually stayed in step.
    for (const entry of schema.mainEntity) {
      expect(index).toContain(`<summary`);
      expect(index).toContain(entry.name);
      expect(index).toContain(entry.acceptedAnswer.text);
    }

    const renderedQuestions = index.match(/<summary[^>]*>/g) ?? [];
    expect(renderedQuestions.length).toBe(schema.mainEntity.length);
  });

  it("serves robots.txt pointing at a sitemap that lists every page", () => {
    const robots = readFileSync(join(dist, "robots.txt"), "utf8");
    expect(robots).toContain("User-agent: *");
    expect(robots).toContain(`Sitemap: ${ORIGIN}/sitemap.xml`);

    const sitemap = readFileSync(join(dist, "sitemap.xml"), "utf8");
    expect(sitemap).toContain("http://www.sitemaps.org/schemas/sitemap/0.9");
    expect(sitemap).toContain(`<loc>${ORIGIN}/</loc>`);
    expect(sitemap).toContain(`<loc>${ORIGIN}/privacy/</loc>`);
    // The 404 is a built page but never a URL to advertise.
    expect(sitemap).not.toContain("/404");
  });

  it("builds a 404 page so unknown paths are not soft-200s", () => {
    // Without dist/404.html, Cloudflare Pages answers an unknown path with
    // the landing page and a 200 — confirmed live on the deployed site.
    const notFound = readFileSync(join(dist, "404.html"), "utf8");
    expect(notFound).toContain('<meta name="robots" content="noindex">');
    expect(notFound).toContain("Not found");
    // It is served at whatever path was mistyped, so it has no canonical
    // URL of its own to claim.
    expect(notFound).not.toContain('rel="canonical"');
  });

  it("exposes the diagram to assistive technology it is labelled for", () => {
    // The diagram <svg> carries role="img" and an aria-label; an
    // aria-hidden ancestor would make both dead weight.
    expect(index).not.toMatch(/<section class="diagram"[^>]*aria-hidden/);
    expect(index).toMatch(/<svg[^>]*role="img"[^>]*aria-label="[^"]+"/);
  });

  it("links the waitlist status message to the input it describes", () => {
    expect(index).toMatch(
      /<input id="waitlist-email"[^>]*aria-describedby="waitlist-message"/,
    );
    expect(index).toMatch(/<p id="waitlist-message"[^>]*role="status"/);
  });

  it("points at the public source from both pages", () => {
    for (const html of [index, privacy]) {
      expect(html).toContain('href="https://github.com/thrwapp/thrw"');
    }
  });
});
