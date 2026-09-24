// Facts about thrw that more than one page or endpoint needs to state.
//
// The deployed origin is deliberately NOT here: it lives once in
// astro.config.mjs's `site` and reaches everything through `Astro.site` or an
// endpoint's `site` param (#231 criterion 4). Adding it here would be the
// second copy that criterion exists to prevent.

export const SITE_NAME = "thrw";

export const REPO_URL = "https://github.com/thrwapp/thrw";

// The root LICENSE. Note the repo is not uniformly MIT: per ADR 0003
// `services/**` is FSL-licensed. This names the licence of the thing a user
// actually installs - the adapters - which is what SoftwareApplication below
// describes, and matches the landing page's own wording ("the wire protocol,
// the relay engine, and every device adapter are MIT-licensed and public").
export const LICENSE_URL = `${REPO_URL}/blob/main/LICENSE`;

/**
 * The platforms the site claims adapters for.
 *
 * One list, two consumers: `label` builds the FAQ answer's prose and `os`
 * builds `SoftwareApplication.operatingSystem`. They were separate before, so
 * structured data could have claimed a platform the page did not mention, or
 * missed one it did.
 *
 * `label` is the marketing name the copy uses ("Mac", "iPad"); `os` is the
 * operating system name a crawler expects ("macOS", "iPadOS"). Keeping both
 * avoids either consumer having to translate the other's vocabulary.
 */
export const PLATFORMS = [
  { label: "Android", os: "Android" },
  { label: "Mac", os: "macOS" },
  { label: "iPad", os: "iPadOS" },
  { label: "Linux", os: "Linux" },
] as const;

/**
 * "a, b, and c" - an Oxford comma list, hand-rolled rather than
 * `Intl.ListFormat`.
 *
 * The output is asserted byte-for-byte by the FAQ copy tests, and
 * `Intl.ListFormat` depends on the ICU data built into whatever Node the build
 * runs on. A locale-data difference between a laptop and a CI runner would
 * change rendered marketing copy, which is not a thing that should be able to
 * happen quietly.
 */
export function andList(items: readonly string[]): string {
  if (items.length < 3) return items.join(" and ");
  return `${items.slice(0, -1).join(", ")}, and ${items[items.length - 1]}`;
}

/**
 * AI crawlers, allowed deliberately.
 *
 * `User-agent: * / Allow: /` already permits every one of these, so these
 * groups change no crawler's behaviour today. They exist for two reasons:
 *
 *  - The policy becomes a decision on the record instead of a side effect of
 *    the wildcard. For a pre-launch waitlist, being quoted by an assistant is
 *    free distribution, which is worth having written down.
 *  - robots.txt group matching is most-specific-wins, so if `*` ever gains a
 *    `Disallow`, these agents keep their access instead of silently inheriting
 *    it. That is the failure this list is really insurance against.
 *
 * `Google-Extended` is listed separately from Googlebot on purpose: it governs
 * Gemini grounding and has no effect on Search ranking, so allowing it is a
 * different decision to allowing Search.
 */
export const AI_CRAWLERS = [
  "GPTBot",
  "OAI-SearchBot",
  "ChatGPT-User",
  "ClaudeBot",
  "anthropic-ai",
  "PerplexityBot",
  "Perplexity-User",
  "Google-Extended",
  "Applebot-Extended",
  "CCBot",
  "meta-externalagent",
] as const;
