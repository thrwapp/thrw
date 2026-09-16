import { defineConfig } from "astro/config";

// Static output: this is a pre-launch marketing page with no server-side
// behaviour (see issue #34, criterion 4 — no backend wiring in this issue).
export default defineConfig({
  output: "static",
});
