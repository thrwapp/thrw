// The site's page routes, derived from the page files themselves.
//
// Extracted from sitemap.xml.ts (#273) because llms.txt needs the same list.
// Two hand-maintained copies of "which pages exist" is exactly the drift the
// sitemap's own glob was written to avoid.

// 404.astro is a real page file but not a URL anyone should be pointed at.
const pageFiles = Object.keys(import.meta.glob("../pages/**/*.astro")).filter(
  (file) => !file.endsWith("/404.astro"),
);

// Trailing slash on sub-pages: Cloudflare Pages 308-redirects /privacy to
// /privacy/, and pointing a crawler at the redirecting form wastes a hop.
function routeFor(file: string): string {
  const route = file.replace(/^\.\.\/pages\//, "").replace(/\.astro$/, "");
  return route === "index" ? "/" : `/${route}/`;
}

/** Every indexable route, sorted, e.g. `["/", "/privacy/"]`. */
export const routes: readonly string[] = pageFiles.map(routeFor).sort();
