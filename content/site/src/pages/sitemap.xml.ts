// Prerendered at build time into dist/sitemap.xml (static output).
//
// The URL list is derived from the page files themselves rather than
// hand-written, so adding a page under src/pages puts it in the sitemap
// without anyone remembering to. Astro's own sitemap integration would do
// this too, but it is a dependency for twenty lines of code on a two-page
// site — see the "no new dependency without justification" rule in
// AGENTS.md.
import type { APIRoute } from "astro";
import { routes } from "../lib/routes";

// The route list moved to ../lib/routes (#273) so llms.txt enumerates exactly
// the same pages. It is still derived from the page files, so adding a page puts
// it in both without anyone remembering to.
//
// No <lastmod>, deliberately: neither available source is honest. A build
// timestamp would claim every page changed on every deploy, and a git-derived
// date depends on the clone depth the CI checkout happens to use. Search engines
// discount a sitemap whose lastmod they learn not to trust, so none beats wrong.
export const GET: APIRoute = ({ site }) => {
  const urls = routes
    .map((route) => `  <url><loc>${new URL(route, site).href}</loc></url>`)
    .join("\n");

  const body = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls}
</urlset>
`;

  return new Response(body, {
    headers: { "Content-Type": "application/xml; charset=utf-8" },
  });
};
