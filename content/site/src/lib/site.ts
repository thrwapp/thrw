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
 * The platforms thrw has a **working** adapter for.
 *
 * One list, two consumers: `label` builds the FAQ answer's prose and `os`
 * builds `SoftwareApplication.operatingSystem`. They were separate before, so
 * structured data could have claimed a platform the page did not mention, or
 * missed one it did.
 *
 * `label` is the marketing name the copy uses ("Mac"); `os` is the operating
 * system name a crawler expects ("macOS"). Keeping both avoids either consumer
 * having to translate the other's vocabulary.
 *
 * ## Why iPad and Linux are not in this list
 *
 * They were, and it was not true. Checked against the repo rather than
 * assumed:
 *
 *  - `packages/adapter-ipad` is a **single-line source file**. There is no
 *    adapter.
 *  - `packages/adapter-linux` has ~500 lines of BlueZ gateway and connection
 *    management, but **no MQTT and no node wiring at all** - that is what
 *    issue #271 is for. It cannot talk to the relay, so it cannot participate
 *    in a handoff.
 *
 * Two of four claimed platforms could not do the thing the site said they
 * did. In prose that was already wrong; once it fed
 * `SoftwareApplication.operatingSystem` and llms.txt it became wrong in a
 * machine-readable form aimed squarely at systems that repeat claims
 * verbatim. This file is where that gets fixed, because it is the one place
 * both consumers read.
 *
 * Move a platform back here when its adapter can actually hold the headset -
 * not when its directory exists.
 */
export const PLATFORMS = [
  { label: "Android", os: "Android" },
  { label: "Mac", os: "macOS" },
] as const;

/**
 * Platforms thrw intends to support and does not yet.
 *
 * Deliberately **prose only**. These never reach
 * `SoftwareApplication.operatingSystem`, because structured data is a claim
 * about what the software runs on today, and a crawler has nowhere to put
 * "planned". Keeping them visible in the copy preserves the roadmap without
 * asserting something false in a field machines read.
 */
export const PLANNED_PLATFORMS = ["iPad", "Linux"] as const;

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
