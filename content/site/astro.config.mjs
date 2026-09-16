import { defineConfig } from "astro/config";

// Static output: the page itself has no server-side rendering. The waitlist
// form's server-side behaviour lives in a separate Cloudflare Pages Function
// (functions/waitlist.ts), which Cloudflare deploys alongside this static
// output independently of Astro's `output` mode (see issue #70).
export default defineConfig({
  output: "static",
});
