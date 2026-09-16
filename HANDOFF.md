# HANDOFF: relay-core priority engine (issue #41)

## What was done

Implemented `PriorityEngine` in `packages/relay-core/src/index.ts` — pure
decision logic for "which node holds the claim right now," per
`docs/spec/architecture.md`'s "Priority rules" section. No MQTT client, no
connection state machine.

- `recordEvent(nodeId, type)` / `endEvent(nodeId, type)` track active
  signals per node, keyed by `EventKind` imported from `@thrw/protocol`.
- `currentHolder()` ranks active signals using `@thrw/protocol`'s
  `PRIORITY_ORDER` (imported, not re-derived) and falls back to the
  last-claimed node (rule 5) when nothing is active.
- Auto-return: when a `"call"` signal ends and no other call is active
  anywhere, if a different node held the claim immediately before that
  call started, a return to that node is scheduled after
  `DEFAULT_AUTO_RETURN_MS` (90s). Any new rule 1-4 signal recorded before
  the timer fires cancels the pending return.
- Time source is injectable via a `Scheduler` interface
  (`{ setTimeout, clearTimeout }`), defaulting to real timers
  (`systemScheduler`). Tests use a `FakeScheduler` that captures callbacks
  instead of waiting on a real clock.

## Wiring snag and how it was resolved

`packages/protocol/package.json` has no `main`/`exports`/`types` field, so
neither `tsc` nor Vite/Vitest could resolve `import ... from "@thrw/protocol"`
out of the box (`Cannot find module` / `Failed to resolve entry for
package`). The issue's "paths the agent must not touch" list forbids
editing anything under `packages/protocol/**`, so the fix lives entirely on
the `relay-core` side instead:

- `packages/relay-core/tsconfig.json` adds a `paths` mapping pointing
  `@thrw/protocol` at `../protocol/dist/index` (protocol's build output).
- `packages/relay-core/vitest.config.ts` (new file) adds a matching
  `resolve.alias` for the test runner.
- Both rely on `packages/protocol` being built first, which `turbo.json`'s
  `dependsOn: ["^build"]` already guarantees now that `@thrw/protocol` is a
  declared dependency in `packages/relay-core/package.json`.

This is a workaround for a pre-existing gap in `packages/protocol`'s
package.json, not a change to its behavior, source, or public API.

## Acceptance criteria evidence

1. 5 priority rules, sourced from `@thrw/protocol`'s `PRIORITY_ORDER`/`EventKind`:
   `packages/relay-core/src/index.ts:1` (import), `:100-113`
   (`computeActiveHolder` iterates `PRIORITY_ORDER`). Tests per rule:
   `packages/relay-core/test/index.test.ts:60-89` (rules 1-4),
   `:44-51` (rule 5).
2. `recordEvent`/`endEvent`/`currentHolder`:
   `packages/relay-core/src/index.ts:59,73,87`.
3. Auto-return default 90s, previous-holder tracking, preemption:
   `packages/relay-core/src/index.ts:9` (`DEFAULT_AUTO_RETURN_MS`),
   `:60-63` (capture previous holder), `:75-82` (schedule on call end),
   `:66-68` (any new signal cancels pending return). Tests:
   `packages/relay-core/test/index.test.ts:122-186`.
4. Injectable time source: `Scheduler` interface,
   `packages/relay-core/src/index.ts:14-22`; constructor option
   `packages/relay-core/src/index.ts:52-55`. `FakeScheduler` in tests
   (`packages/relay-core/test/index.test.ts:6-30`) never uses a real timer.
5. No MQTT client, no connection state machine — confirmed by inspection of
   `packages/relay-core/src/index.ts` (only priority/timer logic).
6. No new runtime dependency beyond the workspace link to `@thrw/protocol`
   (already required by the issue itself). No third-party package added.
7. All 5 rules tested including cross-node non-preemption
   (`packages/relay-core/test/index.test.ts:91-108`), plus auto-return
   fire/preempt/custom-timeout cases (`:122-186`), all against
   `FakeScheduler`, never a real wall-clock wait.

Ran `pnpm turbo test --filter=@thrw/relay-core` — 12 tests passed. Also ran
`pnpm turbo typecheck --filter=@thrw/relay-core`, `pnpm turbo build
--filter=@thrw/relay-core`, and `pnpm turbo test` (whole repo, 16/16 tasks
green) to confirm no regressions.

## Uncertain / left as a judgment call

- Tie-breaking when the *same* event kind is active on two nodes
  simultaneously (e.g. two nodes both have `"voip"` active) isn't specified
  in architecture.md. Implemented as "most recently started wins," mirroring
  rule 5's own last-claimed semantics. Not explicitly covered by a test
  beyond the mechanism being exercised indirectly; flagging in case a
  different tie-break (e.g. first-started, or disallow entirely) was
  intended.
- During the auto-return grace window (after a call ends, before the 90s
  timer fires), the previous call node keeps holding the claim if nothing
  else is active — the timer only fires the explicit hand-back. This
  matches a literal reading of "return to previous holder **after** a
  learned timeout," but if the intent was an instant revert with the timer
  only as a delay-before-final-return in some other sense, that would need
  a different implementation.
