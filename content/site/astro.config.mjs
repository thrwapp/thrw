import { defineConfig } from "astro/config";

// Static output: the page itself has no server-side rendering. The waitlist
// form's server-side behaviour lives in a separate Cloudflare Pages Function
// (functions/waitlist.ts), which Cloudflare deploys alongside this static
// output independently of Astro's `output` mode (see issue #70).
export default defineConfig({
  // The deployed origin. Open Graph consumers reject relative og:url and
  // og:image, and a relative canonical is worthless, so the layout builds
  // both from this — it must stay in step with the Cloudflare Pages custom
  // domain (confirmed live: https://thrw.app serves this site).
  site: "https://thrw.app",
  output: "static",
});
