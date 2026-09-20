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

**How the human-merge rule is actually enforced (#181).** CODEOWNERS on
its own does not enforce it: `main-trunk-protection` sets
`require_code_owner_review: true` but `required_approving_review_count:
0`, and at zero a PR satisfies the review rule with no reviews at all, so
the code-owner requirement never applies. Three PRs merged straight
through it, including one touching `services/**` and one touching
`docs/adr/**`.

Raising the approval count to 1 would fix that but applies to *every* PR,
removing the `packages/**` / `content/site/**` auto-merge lane granted
above — and rulesets cannot condition the pull-request rule on changed
paths. So the rule is enforced by the `codeowners-gate` required check
(`.github/workflows/codeowners-gate.yml`), which passes immediately when
a PR touches no protected path and otherwise demands an approving review
from a CODEOWNERS owner. Both halves of the contract hold: the fast lane
stays open, the protected paths genuinely need a human.

That check restates the four rules above rather than reading CODEOWNERS,
because CODEOWNERS is currently **narrower than this contract**: it
covers `content/site/src/pages/pricing*`, while the rule above is any
path containing `pricing`. Widening CODEOWNERS would be a reasonable
follow-up; until then the check, not CODEOWNERS, is the enforcement.

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
- An issue labeled `local-only` is being picked up manually in Claude
  Code, not by the automated pipeline. `agent-triage.yml` already skips
  it entirely (never auto-labels it `agent-ready`), so a routine agent
  run should never see one — but if you ever do, don't touch it: don't
  remove the label, don't open a PR against it, don't triage or
  re-label it.
- Cost-control default: every new issue defaults to `local-only` unless
  it's explicitly labeled `trivial` at creation time — this is
  deliberate (real API spend comes from agent-code.yml runs, not from
  opening issues), not a bug. Don't add `trivial` to an issue yourself
  to "unblock" it; that's Tom's call to make when opening it.
- If the issue is ambiguous, ask a clarifying comment on the issue rather
  than guessing at intent.
- Never delete or skip a test to make a suite pass.

## Conventions

- Use pnpm, never npm or yarn.
- TypeScript: strict mode.
- Swift: use Swift 6 concurrency features where applicable.
- Android: use Kotlin coroutines for async code.
- No new dependency without justification in the PR description.

## Concurrent sessions and worktrees

More than one agent session can be running against this repo at once,
and git gives no warning when they collide — a `checkout` that moves
HEAD out from under another session reports success exactly like a
normal one. This section is the convention that prevents that. It was
written after a real incident: a session opening an unrelated docs
branch ran `git checkout -b` in the shared checkout while another
session was mid-task on `agent/178-periodic-reregistration`. Nothing
was lost, because the in-flight work was uncommitted and followed the
checkout, but a commit in that window would have landed #178's work on
the docs branch.

- **The shared checkout at the repo root belongs to whoever is already
  working in it.** If you did not start there, never run `checkout`,
  `switch` or `checkout -b` in it.
- **A new branch means a new worktree, created before any edits:**

      git worktree add ../thrw-wt-<topic> -b <branch>

  Put it outside the repo root. `.claude/` is not in `.gitignore`, so
  an in-tree worktree shows up as untracked noise in every other
  session's `git status`.
- **Never bare `git stash` / `git stash pop`.** The stash stack is
  shared across all worktrees, so a `pop` can take a different
  session's work. Use a throwaway WIP commit to set work aside
  instead; if you must stash, tag it (`git stash push -u -m "<tag>"`)
  and restore with `git stash apply <sha>`, never `pop`.
- **Don't reach into another worktree with `git -C`.** Run git from
  the worktree you own. Operate on your own branch only.
- **`git push` and `gh pr create` are still shared state.** Worktrees
  isolate the working tree, not the remote — check `git branch
  --show-current` before pushing, and never push a branch you didn't
  create.
- Worktrees do not share `node_modules`, `.build` or `.gradle`, so a
  fresh worktree needs its own `pnpm install` before it can run tests.

### Claim an issue before you work on it

Worktrees stop two sessions corrupting each other's files. They do
nothing to stop two sessions doing the *same work*, which has already
happened once: #190 was implemented twice, in parallel, by two sessions
neither of which knew the other had started. Both were correct; one had
to be thrown away, and the survivor had to be conflict-resolved against
the other's merged version.

- **Before starting an issue, claim it** — assign it to yourself, or
  comment on it saying you have started. Check for an existing claim
  first.
- **A claim is not a lock.** If one is stale, say so on the issue and
  take it; do not silently work in parallel with someone who is still
  going.
- This matters most for the expensive ones. Duplicating a small CI fix
  costs an afternoon; duplicating something like the ADR 0015 topic
  migration, which touches five packages and needs a coordinated
  redeploy, would be far worse.

## Protocol invariants

The MQTT topic structure and the node interface in `packages/protocol`
(see `docs/spec/architecture.md` and ADR 0001) are frozen contracts. Any
change to them requires a new ADR in `docs/adr/` and human review — never
a routine agent PR, even if it's inside `packages/**`.

The node interface's connection state machine (idle / pre-claim / claim
/ active — see ADR 0013 for why "cooldown" is not a fifth state here)
defined in ADR 0010 and ADR 0011 is a frozen contract in the same way.
Changes require an ADR and human review, not a routine agent PR.

The **resource-type segment** in MQTT topics (ADR 0015) and the
**focus topic** (ADR 0016) are part of that same frozen contract:

    thrw/{account}/nodes/{node}/{resource_type}/events
    thrw/{account}/commands/{node}/{resource_type}
    thrw/{account}/state/{resource_type}
    thrw/{account}/nodes/{node}/focus

Changes require an ADR and human review.

**Command sequence numbers** (ADR 0018) and the **confirmed-outcome
pattern** for claim/release — every command resolving to succeeded /
failed / timed_out within a bounded timeout (ADR 0019) — are part of
that same frozen contract. Changes require an ADR and human review,
not a routine agent PR.

**Note for whoever picks this up:** the currently-running Mac/Pixel
implementation was built against the pre-ADR-0015 topic structure, with
no resource-type segment, and is deployed and working against the live
relay. Adopting ADR 0015 requires a migration — `packages/protocol`'s
topic builders, `packages/relay-core`, `services/relay-hosted` and both
adapters, changed together, since the two structures are mutually
incompatible. With no customers and two devices this is a flag day
rather than a staged rollout, and it should land **before** any
peripheral (hid) adapter work is built on the old structure.

**Reliability work comes before new feature surface.** The three
reliability ADRs — 0018 (state reconciliation and command
idempotency), 0019 (confirmed switch outcomes and failure telemetry)
and 0020 (relay-side debouncing and defined offline behaviour) —
should be implemented and verified against the existing Mac/Pixel
implementation before peripheral (hid) adapter work or further
focus-tracking work begins. All three add guarantees to the shared
claim/release machinery, and retrofitting them gets harder with every
resource type and adapter layered on top of the current two-node
system. This sequencing sits alongside the ADR 0015 migration above,
which is the other thing gating hid work.

ADR 0018's command sequence number and the ADR 0015 topic migration
change the same payloads in the same packages, and both are flag days
across `packages/protocol`, `packages/relay-core`,
`services/relay-hosted` and both adapters. **Land them together**, or
if they must be split, 0015 first — see ADR 0018's "Sequencing against
the ADR 0015 migration".

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
