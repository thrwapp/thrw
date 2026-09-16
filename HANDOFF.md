# HANDOFF: issue #69 — "How it works" + FAQ sections

## What was done

Added two new sections to `content/site/src/pages/index.astro`, placed
inside `<main>` after the existing device-switching diagram and before
the closing `</main>` tag (footer untouched):

- **"How it works"** (lines 65-85): a 4-step `<ol>` — each device runs
  a small adapter, the adapter watches for real triggers (call
  starting, meeting beginning, playback starting), the headset follows
  the trigger to whichever device needs it, and it works across
  Android/Mac/iPad/Linux. Wording is grounded in
  `docs/spec/architecture.md`'s "What thrw is" and "System components"
  sections and explicitly avoids any instant/zero-latency claim (the
  existing hero copy already disclaims that).
- **FAQ** (lines 87-111): 5 question/answer pairs using native
  `<details>/<summary>` (no JS needed, no new dependency):
  - "Is switching instant?" → no, matches the hero's own disclaimer.
  - "What devices does it support?" → Android, Mac, iPad, Linux, per
    architecture.md's adapter list.
  - "Do I need root or a jailbreak?" → no, per ADR 0002 (sequential
    handoff was chosen specifically to avoid a root requirement).
  - "Does this replace Apple's own device switching?" → grounded in
    architecture.md's "Positioning" section (not marketed as faster
    than Apple, advantage is cross-ecosystem reliability).
  - "How does thrw decide which device gets the headset?" → the
    priority order from architecture.md's "Priority rules" section
    (call > manual claim > VoIP > media > last-claimed).

Styling (lines 292-361ish) reuses the existing design tokens defined
in the `<style>` block's `:root` (`--space-*`, `--color-*`,
`--measure`), plus one new token, `--font-size-h2`, added next to the
existing `--font-size-h1` since no section-heading size token existed
yet. No new colors, spacing scale, or font stack was introduced.

## Verification

Ran the exact command from the issue:

    pnpm turbo build test --filter=@thrw/site

All 4 existing tests in `content/site/test/index.test.ts` pass
unmodified (hero headline, CTA text, CTA link, both body paragraphs).
Also ran `pnpm turbo typecheck --filter=@thrw/site` — 0 errors/warnings.

## Uncertain / not verified

- No visual/browser check was done (no running browser available in
  this environment) — only build output and automated test assertions
  were checked. The `<details>` accordion styling and step-index
  circles haven't been eyeballed in a real browser, light or dark
  mode.
- Did not touch `content/site/src/pages/pricing*` (doesn't exist yet)
  or anything under `.github/**` — out of scope per the issue.
