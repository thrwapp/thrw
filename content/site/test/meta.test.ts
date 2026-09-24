import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { beforeAll, describe, expect, it } from "vitest";
// Imported rather than restated: these assertions are only worth anything if
// they compare the built output against the one list the site generates from
// (#273). A copy here would pass while the page claimed something else.
import { AI_CRAWLERS, PLANNED_PLATFORMS, PLATFORMS } from "../src/lib/site";

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

    // One @graph now, not a bare FAQPage (#273) - find the FAQ node in it.
    const graph = JSON.parse(block![1])["@graph"] as Record<string, any>[];
    const schema = graph.find((node) => node["@type"] === "FAQPage");
    expect(schema, "no FAQPage node in the graph").toBeTruthy();
    expect(schema!.mainEntity.length).toBeGreaterThan(0);

    // The page markup and the structured data are generated from one array
    // in index.astro; this asserts they actually stayed in step.
    for (const entry of schema!.mainEntity) {
      expect(index).toContain(`<summary`);
      expect(index).toContain(entry.name);
      expect(index).toContain(entry.acceptedAnswer.text);
    }

    const renderedQuestions = index.match(/<summary[^>]*>/g) ?? [];
    expect(renderedQuestions.length).toBe(schema!.mainEntity.length);
  });

  // #273. Everything below is about being legible to a machine that has never
  // seen the page: what thrw *is*, not just what its FAQ says.
  it("identifies the site, the organisation and the software as linked entities", () => {
    const block = index.match(
      /<script type="application\/ld\+json">(.*?)<\/script>/s,
    );
    const graph = JSON.parse(block![1])["@graph"] as Record<string, any>[];
    const types = graph.map((node) => node["@type"]);
    expect(types).toContain("WebSite");
    expect(types).toContain("Organization");
    expect(types).toContain("SoftwareApplication");

    // A graph whose cross-references dangle is worse than three separate
    // blocks: it asserts a relationship to a node that is not there.
    const ids = new Set(graph.map((node) => node["@id"]));
    const referenced = [...JSON.stringify(graph).matchAll(/"@id":"([^"]+)"/g)].map(
      (match) => match[1],
    );
    for (const ref of referenced) {
      expect(ids.has(ref), `dangling @id reference: ${ref}`).toBe(true);
    }

    const org = graph.find((node) => node["@type"] === "Organization")!;
    expect(org.logo).toBe(`${ORIGIN}/apple-touch-icon.png`);
    expect(org.sameAs).toContain("https://github.com/thrwapp/thrw");
    expect(existsSync(join(dist, "apple-touch-icon.png"))).toBe(true);
  });

  it("claims the same platforms in structured data as the page does in prose", () => {
    const block = index.match(
      /<script type="application\/ld\+json">(.*?)<\/script>/s,
    );
    const graph = JSON.parse(block![1])["@graph"] as Record<string, any>[];
    const software = graph.find((node) => node["@type"] === "SoftwareApplication")!;

    // The whole point of the shared PLATFORMS list: these cannot diverge.
    expect(software.operatingSystem).toBe(
      PLATFORMS.map((platform) => platform.os).join(", "),
    );

    // And the page's own copy still names every one of them, in both the FAQ
    // answer and the meta description.
    const description = metaContent(index, "name", "description") ?? "";
    for (const { label } of PLATFORMS) {
      expect(index, `FAQ prose is missing ${label}`).toContain(label);
      expect(description, `meta description is missing ${label}`).toContain(label);
    }
  });

  it("never claims a planned platform as one it runs on", () => {
    const block = index.match(
      /<script type="application\/ld\+json">(.*?)<\/script>/s,
    );
    const graph = JSON.parse(block![1])["@graph"] as Record<string, any>[];
    const software = graph.find((node) => node["@type"] === "SoftwareApplication")!;

    // The regression this exists to prevent. iPad and Linux were listed as
    // supported platforms while `adapter-ipad` was a one-line file and
    // `adapter-linux` had no MQTT wiring at all - so the claim was already
    // untrue in prose, and structured data made it untrue in a form built to
    // be repeated by machines. Prose may name them as planned; this field may
    // not name them at all.
    for (const label of PLANNED_PLATFORMS) {
      expect(
        software.operatingSystem,
        `operatingSystem claims ${label}, which has no working adapter`,
      ).not.toContain(label);
    }

    const description = metaContent(index, "name", "description") ?? "";
    for (const label of PLANNED_PLATFORMS) {
      expect(
        description,
        `meta description claims ${label} without saying it is planned`,
      ).not.toContain(label);
    }
  });

  it("still names the planned platforms somewhere, as planned", () => {
    // The other half of the rule above: omitting them entirely would hide a
    // roadmap people reasonably want. The page must say both things - these
    // are coming, and they do not work yet.
    for (const label of PLANNED_PLATFORMS) {
      expect(index, `page no longer mentions ${label} at all`).toContain(label);
    }
    expect(index).toContain("planned and not working yet");
  });

  it("makes no price claim while thrw is pre-launch", () => {
    const block = index.match(
      /<script type="application\/ld\+json">(.*?)<\/script>/s,
    );
    const graph = JSON.parse(block![1])["@graph"] as Record<string, any>[];
    const software = graph.find((node) => node["@type"] === "SoftwareApplication")!;
    // Pricing is undecided, so "free" would be an assertion nobody has made.
    // The source being MIT is a different statement to the product being free.
    expect(software.offers).toBeUndefined();
    expect(software.isAccessibleForFree).toBeUndefined();
  });

  it("serves llms.txt covering every page the sitemap lists", () => {
    const llms = readFileSync(join(dist, "llms.txt"), "utf8");
    expect(llms.startsWith("# thrw")).toBe(true);

    const sitemapRoutes = [
      ...readFileSync(join(dist, "sitemap.xml"), "utf8").matchAll(
        /<loc>([^<]+)<\/loc>/g,
      ),
    ].map((match) => match[1]);
    expect(sitemapRoutes.length).toBeGreaterThan(0);
    for (const url of sitemapRoutes) {
      expect(llms, `llms.txt does not mention ${url}`).toContain(url);
    }

    // The latency honesty is load-bearing, not decoration: this is the summary
    // an assistant is most likely to repeat, and the landing page deliberately
    // refuses to promise a number.
    expect(llms).toContain("not an instant swap");
    expect(llms).toContain("pre-launch");
  });

  it("allows the AI crawlers explicitly, not just by wildcard", () => {
    const robots = readFileSync(join(dist, "robots.txt"), "utf8");
    for (const agent of AI_CRAWLERS) {
      expect(robots, `robots.txt does not name ${agent}`).toContain(
        `User-agent: ${agent}`,
      );
    }
    // Google-Extended governs Gemini grounding independently of Search, so its
    // presence is a separate decision worth keeping asserted.
    expect(robots).toContain("User-agent: Google-Extended");
    expect(robots).not.toContain("Disallow:");
  });

  it("lets search engines use the card at full size, except on the 404", () => {
    for (const html of [index, privacy]) {
      const robots = metaContent(html, "name", "robots") ?? "";
      expect(robots).toContain("max-image-preview:large");
      expect(robots).toContain("max-snippet:-1");
      expect(robots).not.toContain("noindex");
    }
    // The 404 stays noindex-only: it has no canonical to claim and no business
    // being surfaced at all.
    const notFound = readFileSync(join(dist, "404.html"), "utf8");
    expect(metaContent(notFound, "name", "robots")).toBe("noindex");
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
