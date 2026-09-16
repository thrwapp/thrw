# AGENTS.md

This is the contract every agent (Claude Code, or anyone else automating
changes in this repo) works under. It applies alongside — never instead of
— `docs/spec/architecture.md` and `docs/adr/`. If this file and an ADR ever
disagree, the ADR wins for architecture; this file wins for process.

## Scope

- **`packages/**`** is open, agent-owned. A PR here can auto-merge once CI
  is green and the evaluator (`agent-eval.yml`) passes — no human review
  required by default.
- **`content/site/**`** (the marketing site) is open, agent-owned, same as
  `packages/**` — a PR here can auto-merge once CI is green and the
  evaluator passes. The pricing-path rule below already reaches into it
  (`content/site/src/pages/pricing*` is CODEOWNERS-gated), so nothing
  further needs carving out here.
- **`services/**`** is FSL-licensed (see ADR 0003). Agents may propose
  changes here, but every PR requires human merge via CODEOWNERS,
  regardless of who authored it.
- **`.github/**`**, any file whose path contains `pricing`, and
  **`docs/adr/**`** are always human-merge, no exceptions, regardless of
  which top-level directory they otherwise sit under.

## Definition of done

A task is not done until all of the following are true:

1. Tests pass via `pnpm turbo test --filter=<pkg>` for every package touched.
2. Every acceptance criterion in the linked issue is addressed, cited with
   file+line evidence in the PR description (not just asserted).
3. A handoff doc is written in the branch at `docs/handoffs/<issue-number>.md`
   describing what was done and what's uncertain — see Honesty requirement
   below. Use the issue number, not a shared `HANDOFF.md`: every agent PR
   used to overwrite the same root file, which meant near-constant merge
   conflicts between concurrently-developed branches and threw away every
   prior PR's handoff notes the moment the next one landed. A per-issue
   path can never collide with another issue's file.
4. The commit message follows Conventional Commits format.

## Stop conditions

- After 5 failed test-fix cycles on the same issue, stop. Comment on the
  issue explaining exactly what's blocking, add the `needs-human` label,
  and stop — do not keep retrying.
- If the issue is ambiguous, ask a clarifying comment on the issue rather
  than guessing at intent.
- Never delete or skip a test to make a suite pass.

## Conventions

- Use pnpm, never npm or yarn.
- TypeScript: strict mode.
- Swift: use Swift 6 concurrency features where applicable.
- Android: use Kotlin coroutines for async code.
- No new dependency without justification in the PR description.

## Protocol invariants

The MQTT topic structure and the node interface in `packages/protocol`
(see `docs/spec/architecture.md` and ADR 0001) are frozen contracts. Any
change to them requires a new ADR in `docs/adr/` and human review — never
a routine agent PR, even if it's inside `packages/**`.

The node interface's connection state machine (idle / pre-claim / claim
/ active — see ADR 0013 for why "cooldown" is not a fifth state here)
defined in ADR 0010 and ADR 0011 is a frozen contract in the same way.
Changes require an ADR and human review, not a routine agent PR.

## Build-time configuration, not hardcoded endpoints

Per ADR 0005, every adapter must read its relay URL and licensing
endpoint from build-time configuration (a config file per adapter), never
hardcoded inline in source. This is a standing rule, not a code-review
nice-to-have — self-hosting depends on it.

## Honesty requirement

Report what actually happened, including partial completion, skipped
steps, or uncertainty. Never imply something works when it wasn't
actually verified — "tests pass" means you ran them and saw them pass,
not that they should pass.

## Naming

The GitHub org is `thrwapp`, but the published package scope is `@thrw/*`
(e.g. `@thrw/protocol`), not `@thrwapp/*`.
