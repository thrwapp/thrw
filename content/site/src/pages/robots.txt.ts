// Prerendered at build time into dist/robots.txt (static output).
//
// An endpoint rather than a file in public/ so the origin comes from
// `site` in astro.config.mjs — the same place the canonical, og:url and
// sitemap get it — instead of being a third hardcoded copy of the domain.
import type { APIRoute } from "astro";
import { AI_CRAWLERS } from "../lib/site";

export const GET: APIRoute = ({ site }) => {
  // See AI_CRAWLERS' own comment for why these are spelled out when the
  // wildcard above already allows them: it puts the policy on the record, and
  // keeps their access if `*` ever gains a Disallow.
  const aiGroups = AI_CRAWLERS.map((agent) => `User-agent: ${agent}\nAllow: /\n`).join("\n");

  const body = `User-agent: *
Allow: /

# AI crawlers and assistant fetchers, allowed deliberately (#273). Being quoted
# by an assistant is distribution, which is what a pre-launch waitlist wants.
${aiGroups}
Sitemap: ${new URL("/sitemap.xml", site).href}
`;

  return new Response(body, {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
};
