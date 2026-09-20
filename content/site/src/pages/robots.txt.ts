// Prerendered at build time into dist/robots.txt (static output).
//
// An endpoint rather than a file in public/ so the origin comes from
// `site` in astro.config.mjs — the same place the canonical, og:url and
// sitemap get it — instead of being a third hardcoded copy of the domain.
import type { APIRoute } from "astro";

export const GET: APIRoute = ({ site }) => {
  const body = `User-agent: *
Allow: /

Sitemap: ${new URL("/sitemap.xml", site).href}
`;

  return new Response(body, {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
};
