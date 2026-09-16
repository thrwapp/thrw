# HANDOFF: Wire up the waitlist CTA to Buttondown (issue #70)

## What was done

- **Cloudflare Pages Function** — `content/site/functions/waitlist.ts`.
  Cloudflare's file-based routing maps this file to `POST /waitlist`. It:
  - Parses the JSON request body and validates the `email` field with a
    basic regex (`content/site/functions/waitlist.ts:14,26-32`).
  - Reads the Buttondown API key from `env.BUTTONDOWN_API_KEY` — never
    hardcoded, never committed (`content/site/functions/waitlist.ts:1-6,34-39`).
  - Calls `POST https://api.buttondown.email/v1/subscribers` with
    `Authorization: Token <key>` server-side, using the runtime's native
    `fetch` (no HTTP client dependency added) (`content/site/functions/waitlist.ts:46-60`).
  - Returns a JSON error body with a non-2xx status on invalid input,
    missing config, network failure, or a non-OK Buttondown response
    (`content/site/functions/waitlist.ts:29-31,41-44,55-58,62-64`), and
    `{ ok: true }` on success (`content/site/functions/waitlist.ts:67`).

- **Real form in `index.astro`** — replaced the static
  `<a class="cta" href="#">Join the waitlist</a>` with a `<form
  id="waitlist-form">` containing a labeled `<input type="email" required>`
  and a `<button type="submit" class="cta">Join the waitlist</button>`
  (`content/site/src/pages/index.astro:32-37`). A plain inline `<script>`
  (no framework, no new dependency) intercepts the submit, `fetch`s
  `/waitlist` with the email as JSON, disables the button while in
  flight, and updates a `role="status" aria-live="polite"` message
  element with a success or error string without a full page reload
  (`content/site/src/pages/index.astro:76-120`). Matching CSS was added
  for the form, input, disabled button state, and success/error message
  colors (`content/site/src/pages/index.astro:280-331`), plus a
  `.visually-hidden` utility for the email `<label>`.

- **Test update (criterion 3)** — `content/site/test/index.test.ts`'s
  `"renders the call-to-action as a real link"` test asserted the CTA was
  a bare `<a>Join the waitlist</a>`. That assumption is superseded by the
  real form now required, so it was replaced with an assertion that a
  `<form id="waitlist-form">` and a `<button type="submit">Join the
  waitlist</button>` are present (`content/site/test/index.test.ts:42-47`).
  The hero headline and both body paragraph assertions were **not**
  touched — still asserting the exact frozen strings.

- **`astro.config.mjs` comment** updated — the old comment claimed "no
  backend wiring in this issue," which is no longer true now that a
  Cloudflare Pages Function exists alongside the static build output.
  Clarified that `output: "static"` still governs only Astro's own
  rendering; the Function is a separate, independently-deployed piece
  (`content/site/astro.config.mjs:1-6`).

## Required human step (cannot be done from this PR)

Per the issue, set the `BUTTONDOWN_API_KEY` environment variable directly
in the **Cloudflare Pages project's dashboard** (Settings → Environment
variables, for both Production and Preview if waitlist testing on preview
deploys is wanted), using a real Buttondown API token. Nothing in this
repo or CI can set this — it must be a manual step in Cloudflare's UI. If
that dashboard has separate settings for Pages *Functions* environment
variables (as distinct from build-time variables), use that one.

## Test results

Ran the exact command from the issue:

```
pnpm turbo build test --filter=@thrw/site
```

Both the `build` and `test` tasks passed (4/4 tests green), including the
updated CTA assertion. Output confirmed locally, not just assumed.

## Uncertain / not verified

- **Not tested against the live Buttondown API** — no API key is
  available in this environment, so the actual `POST
  https://api.buttondown.email/v1/subscribers` call, its exact success/
  error response shapes, and Buttondown-side duplicate-email behavior are
  unverified. The function treats any non-OK response as a generic error;
  if Buttondown returns a more specific/user-friendly error body worth
  surfacing (e.g. "already subscribed"), that would need real-key testing
  to confirm the response shape and could be a small follow-up.
- **Cloudflare Pages Functions detection in the deploy workflow** —
  `.github/workflows/deploy-site.yml` runs `cloudflare/pages-action@v1`
  with `directory: content/site/dist`. I did not verify whether Wrangler/
  the Pages action picks up `content/site/functions/` correctly in this
  monorepo layout (it may need a `workingDirectory: content/site` input,
  or none at all — Cloudflare's direct-upload convention for functions
  can be sensitive to the cwd the action runs Wrangler from). I did not
  change `.github/**` myself since it's always human-merge per AGENTS.md
  and out of scope for this issue, but whoever reviews this should
  double check the first real deploy actually serves `/waitlist` (e.g.
  via `curl -X POST .../waitlist` against the live site) rather than
  404ing.
- No browser end-to-end test of the form (no dev server / real network
  available here) — verified only via the built HTML output and the
  vitest assertions, per AGENTS.md's honesty requirement: this is not a
  claim that the UI was clicked through in a browser.
- Did not add `@cloudflare/workers-types` as a dev dependency; the
  function file uses a small hand-written `Env`/context interface
  instead to avoid an unjustified new dependency (issue criterion 5).
  This means editor/IDE type support for the full Pages Functions API
  surface (e.g. `context.waitUntil`, KV bindings) is not available if a
  future change needs it.
