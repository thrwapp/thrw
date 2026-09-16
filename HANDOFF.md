# HANDOFF: content/site Astro scaffold + pre-launch landing page (#34)

## What was done

- Scaffolded an Astro project at `content/site`, package name `@thrw/site`
  (content/site/package.json:2), matching the `@thrw/<name>` convention
  used by `packages/testkit/package.json:2`. `pnpm-workspace.yaml` already
  globs `content/*`, and `pnpm install` picks the package up — it appears
  in the lockfile's importers as `content/site:` (pnpm-lock.yaml) and
  `pnpm install --frozen-lockfile` is clean against the committed lockfile.
- Scripts (content/site/package.json:7-10): `dev` → `astro dev`,
  `build` → `astro build` (outputs to `dist/`, covered by `turbo.json`'s
  existing `build` output glob), `typecheck` → `astro check`,
  `test` → `vitest run`. No `lint` script and no lint tool added, per
  criterion 2.
- Both known blockers from the prior two attempts are handled:
  - `typescript` pinned to `6.0.3` as a devDependency scoped to this
    package (content/site/package.json:18), so the root `typescript@7.0.2`
    doesn't reach `astro check`.
  - `@types/node` at `22.20.3` (content/site/package.json:17) so the
    Node built-in imports in the test file typecheck.
  - `@astrojs/check` at `0.9.10` (content/site/package.json:16), which
    `astro check` requires. Verified by removing it and re-running:
    "The `@astrojs/check` and `typescript` packages are required for this
    command to work."
  - `astro check` now reports **0 errors, 0 warnings, 0 hints** across
    4 files (verified locally, output in the PR description).
- `content/site/src/pages/index.astro` renders the reviewed copy verbatim:
  headline (line 21), the two body paragraphs (lines 22-23), and the
  "Join the waitlist" CTA (line 24). Each string sits on a single source
  line so the built HTML contains it character-for-character; I verified
  each paragraph byte-for-byte against the issue body with `grep -c` on
  `gh issue view 34 --json body`.
- The CTA is a static `<a href="#">` — no email-capture backend, no
  third-party form service, no pricing page, no checkout (criterion 4).
  Nothing under `content/site/src/pages/pricing*` was created.
- `content/site/test/index.test.ts` reads the built `dist/index.html` and
  asserts it contains the exact headline and CTA strings (plus both body
  paragraphs, and that the CTA renders as a real `<a>` element). Uses the
  repo's existing `vitest`, resolved from the workspace root exactly as
  `packages/testkit` and the `services/*` packages do — no new test
  framework.

## Deviations / things worth knowing

- **Added `content/site/turbo.json`.** Running
  `pnpm turbo build typecheck test --filter=@thrw/site` with only the root
  config ran all three tasks concurrently, and `build` and the test's own
  build raced over `dist/`, failing with
  `ENOENT: ... dist/pages/index.astro.mjs`. The package-level config
  (`extends: ["//"]`) makes this package's `typecheck` and `test` depend on
  its own `build`, which both fixes the race and means the test asserts on
  a genuinely fresh build. Root `turbo.json` is untouched. This matters for
  CI too: `ci.yml` runs `turbo lint typecheck test` without `build`, so the
  dependency is what guarantees `dist/index.html` exists when the test runs.
- **Added `content/site/.gitignore`** for Astro's generated `.astro/`
  directory; the root `.gitignore` already covers `dist/`.
- `HANDOFF.md` at the repo root is the one file touched outside
  `content/site/**` (plus `pnpm-lock.yaml`, which `pnpm install` must
  update for a new workspace member). Root `HANDOFF.md` is where the
  previous agent PR (#29) put it and what AGENTS.md's definition of done
  asks for.
- pnpm reports two peer-dependency warnings — `tsconfck@3.1.6` and
  `zod-to-ts@1.2.0`, both transitive under Astro, want `typescript@^5`
  and see `6.0.3`. They are warnings only; build, `astro check` and the
  tests all pass. Worth revisiting whenever Astro's transitive deps widen
  their TypeScript peer ranges, or when the repo moves off `typescript@7`
  at the root and this package's override can be dropped.
- Dependency versions are pinned exactly, matching the root
  `package.json`'s style (`turbo`, `typescript`, `vitest` are all exact).

## Not done / uncertain

- No email capture. Deliberate and explicitly out of scope (criterion 4);
  needs a follow-up issue once a service is chosen.
- No deployment wiring. `deploy.yml` doesn't reference `content/site`, and
  nothing in the issue asked for it — so the built site isn't published
  anywhere yet. Flagging it as the obvious next gap, not something I
  changed.
- The page is a single unstyled-ish `index.astro` with a small inline
  `<style>` block: no layout component, no design system, no fonts or
  assets. That's the minimum criterion 3 asks for; a real visual design
  is a separate piece of work.
- Only verified on Node 22.23.2 / pnpm 10.34.5 locally (`.nvmrc` pins the
  Node major CI uses).
- One fragility found while verifying, not fixed here because fixing it
  means changing Astro's behaviour: `astro check` resolves
  `@astrojs/check` with a bare `await import()` from inside astro's own
  directory (astro/dist/cli/install-package.js:11-14), so it depends on
  pnpm having hoisted `@astrojs/check` into `node_modules/.pnpm/node_modules/`.
  A clean `pnpm install` does that, so CI is fine — but an incremental
  `pnpm remove`/`pnpm add` locally can leave it unhoisted, and in that
  state `astro check` prints "Astro requires the following dependency to
  be installed" and **still exits 0**, so `turbo typecheck` reports
  success without having typechecked anything. `pnpm install --force`
  fixes the local layout. If this ever bites in CI, the fix is to make
  the `typecheck` script fail loudly on that message.
