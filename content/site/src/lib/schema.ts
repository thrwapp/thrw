// The homepage's JSON-LD, as one @graph.
//
// Before #273 the only structured data was FAQPage, so the site answered
// questions about a product a crawler had no machine-readable description of:
// no name, no logo, no repository, no licence, no operating systems. Those are
// the facets the cross-ecosystem pitch rests on, and they existed only as
// prose.
//
// One <script> with a @graph rather than three separate blocks, so the nodes
// can reference each other by @id - a consumer reading the SoftwareApplication
// can follow `author` to the Organization instead of guessing they are related.
import { LICENSE_URL, PLATFORMS, REPO_URL, SITE_NAME } from "./site";

export interface FaqEntry {
  question: string;
  answer: string;
}

/**
 * Builds the graph for the landing page.
 *
 * `site` comes from `Astro.site` (astro.config.mjs) rather than being
 * hardcoded, so every URL and @id here is derived from the one place the origin
 * is defined. `description` is the page's own meta description, passed in
 * rather than duplicated, so the graph cannot describe the site differently to
 * the `<meta>` tag two lines above it in the same <head>.
 */
export function buildHomepageGraph(
  site: URL,
  description: string,
  faq: readonly FaqEntry[],
): Record<string, unknown> {
  const origin = new URL("/", site).href;
  const id = (fragment: string) => `${origin}#${fragment}`;

  return {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "WebSite",
        "@id": id("website"),
        url: origin,
        name: SITE_NAME,
        description,
        inLanguage: "en",
        publisher: { "@id": id("organization") },
      },
      {
        "@type": "Organization",
        "@id": id("organization"),
        name: SITE_NAME,
        url: origin,
        // The apple-touch icon rather than favicon.svg: it is a real raster at
        // a known size, which is what logo consumers are least fussy about.
        logo: new URL("/apple-touch-icon.png", site).href,
        sameAs: [REPO_URL],
      },
      {
        "@type": "SoftwareApplication",
        "@id": id("software"),
        name: SITE_NAME,
        url: origin,
        applicationCategory: "UtilitiesApplication",
        // Mirrors the FAQ's own platform claim - same array builds both.
        operatingSystem: PLATFORMS.map((platform) => platform.os).join(", "),
        description,
        license: LICENSE_URL,
        author: { "@id": id("organization") },
        // Deliberately no `offers` and no `isAccessibleForFree`. thrw is
        // pre-launch and its pricing is undecided, so any price claim here -
        // including "free" - would be structured data asserting something
        // nobody has decided. The source being MIT is not the same statement as
        // the hosted product being free.
      },
      {
        "@type": "FAQPage",
        "@id": id("faq"),
        isPartOf: { "@id": id("website") },
        about: { "@id": id("software") },
        mainEntity: faq.map((entry) => ({
          "@type": "Question",
          name: entry.question,
          acceptedAnswer: { "@type": "Answer", text: entry.answer },
        })),
      },
    ],
  };
}
