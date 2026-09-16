import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

// packages/protocol has no "main"/"exports" field (and we must not modify
// packages/protocol/** per this package's issue), so point the test runner
// at its build output directly. turbo's test task depends on ^build, so
// packages/protocol/dist is already built by the time this runs.
export default defineConfig({
  resolve: {
    alias: {
      "@thrw/protocol": fileURLToPath(new URL("../protocol/dist/index.js", import.meta.url)),
    },
  },
});
