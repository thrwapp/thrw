// Prerendered at build time into dist/sitemap.xml (static output).
//
// The URL list is derived from the page files themselves rather than
// hand-written, so adding a page under src/pages puts it in the sitemap
// without anyone remembering to. Astro's own sitemap integration would do
// this too, but it is a dependency for twenty lines of code on a two-page
// site — see the "no new dependency without justification" rule in
// AGENTS.md.
import type { APIRoute } from "astro";

const pageFiles = Object.keys(import.meta.glob("./**/*.astro"));

function routeFor(file: string): string {
  const route = file.replace(/^\.\//, "").replace(/\.astro$/, "");
  return route === "index" ? "/" : `/${route}`;
}

export const GET: APIRoute = ({ site }) => {
  const urls = pageFiles
    .map(routeFor)
    .sort()
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
