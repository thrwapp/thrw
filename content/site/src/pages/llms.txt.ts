// Prerendered at build time into dist/llms.txt (static output).
//
// The llmstxt.org convention: a short, curated markdown map of the site for
// LLM consumers, which have to reconstruct the same thing from HTML otherwise.
//
// Worth being straight about its status: this is a *proposed* convention, and
// there is no confirmation that the major assistants read it. It is a few lines
// of generated text on a two-page site, so the cost of being early is roughly
// nothing - but it should not be mistaken for a mechanism with known reach, and
// it is not a substitute for the content that would actually get thrw cited
// (#274).
//
// An endpoint rather than a file in public/ for the same reason robots.txt and
// sitemap.xml are: the origin comes from `site` in astro.config.mjs instead of
// being hardcoded here.
import type { APIRoute } from "astro";
import { routes } from "../lib/routes";
import { andList, PLANNED_PLATFORMS, PLATFORMS, REPO_URL, SITE_NAME } from "../lib/site";

// Curated one-liners per route. A route with no entry still gets listed - the
// list comes from the page files (../lib/routes), so a new page cannot go
// missing here, it just appears without a description until someone writes one.
const ROUTE_NOTES: Record<string, string> = {
  "/": "What thrw does, how the handoff works, the FAQ, and the waitlist form.",
  "/privacy/": "What each adapter sends to the relay, what is never collected, and how to run your own relay.",
};

export const GET: APIRoute = ({ site }) => {
  const platforms = andList(PLATFORMS.map((platform) => platform.label));
  const planned = andList([...PLANNED_PLATFORMS]);
  const pages = routes
    .map((route) => {
      const url = new URL(route, site).href;
      const note = ROUTE_NOTES[route];
      return note ? `- [${url}](${url}): ${note}` : `- [${url}](${url})`;
    })
    .join("\n");

  // Every claim below is one the site itself makes. In particular the honesty
  // about switch latency is not decoration: the landing page deliberately
  // refuses to promise a number, and a summary that quietly implied "instant"
  // would misrepresent the product to the readers most likely to repeat it.
  const body = `# ${SITE_NAME}

> ${SITE_NAME} switches your Bluetooth headset to whichever of your devices needs it - a call, a meeting, playback starting - across ${platforms}, rather than only within one vendor's ecosystem.

## What it is

- A small adapter runs on each of your devices. A relay arbitrates which one should hold the headset.
- The handoff is a real disconnect-and-reconnect, not an instant swap, so it takes a few seconds. ${SITE_NAME} does not claim a latency number, because none has been published against real hardware.
- Priority order: an incoming or outgoing call wins, then a manual claim, then a VoIP session, then media playback, then whichever device claimed it last.
- No root and no jailbreak on any device.
- Working adapters: ${platforms}. ${planned} adapters are planned and do not work yet.
- Status: pre-launch. The site collects waitlist signups; there is no release to download yet.

## Open source

- The wire protocol, the relay engine and every device adapter are MIT-licensed and public.
- Each adapter reads its relay address from build-time configuration, so you can point your devices at a relay you run yourself.
- Source: ${REPO_URL}

## Pages

${pages}
`;

  return new Response(body, {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
};
