# v1 scenario set

This file is the contract for v1. A scenario listed here is a promise
about what thrw does on the reference pair (AirPods Pro 2, Pixel 10 Pro,
MacBook Air 13" M4 — see `architecture.md`, "Reference hardware"). A
behaviour not listed here is not a v1 promise, however reasonable it
looks.

It exists because, before 2026-09-28, "reliable" had no definition. Bugs
were found by hand, fixed against mocks, and shipped. Two releases in a
row (v0.2.2, v0.2.3) carried defects found only on hardware. A named,
executable scenario set is what turns that loop into one an agent can
work inside.

## Rules

- **Every scenario has an ID, and the ID is stable.** Tests, QA passes,
  issues and handoffs cite it (`M5`, `N2`). IDs are never reused; a
  withdrawn scenario is struck through, not deleted.
- **Every scenario is executable in two places**: the deterministic
  simulator (Phase 1 of the v1 plan in `docs/roadmap.md`), and a
  scripted hardware pass recorded in `docs/testing/`. A scenario that
  passes in only one of them has not passed.
- **A bug is reproduced as a failing scenario before it is fixed.**
  If no existing scenario fails, either the bug is outside v1 or this
  file is missing a scenario — add it here first, in the same PR.
- **"Must not move" and "must recover" rank equally with "must move".**
  Most of the September bugs (#251, #288, #295, #298, #303, #307) were
  thrw moving the headset when it should not have, or failing to recover.
- Adding, removing or changing the expected outcome of a scenario is a
  product decision. Tom's call, in review.

## Terms

- **Holder** — the device the relay believes holds the headset.
- **Route** — where audio actually plays, as observed on the device
  (ADR 0018 decision 2), not whether a Bluetooth link exists.
- **Moves** — a claim is dispatched, resolves `succeeded` (ADR 0019),
  and the route is observed on the target device.
- **Stays** — no claim or release is dispatched, and the route does not
  change.
- **Stuck state** — the route is somewhere a scenario says it should not
  be, and nothing short of a manual claim, an adapter restart or waiting
  out a timeout longer than 90s would change it. #303 and #307 are the
  canonical examples. One stuck state fails v1's exit criteria.
- **Switch success** — a switch that the scenarios say should happen and
  that `Moves` within ADR 0019's outcome bound. The rate's denominator is
  every switch that should have happened, not every command sent.

## Must move

| ID | Situation | Expected | Last verified on hardware |
|---|---|---|---|
| M1 | Incoming call on the Pixel, headset on the Mac | Moves to the Pixel, landing no later than the call being answered | 2026-09-26, #310 (lands at answer, not ring) |
| M2 | Outgoing call placed on the Pixel | Moves to the Pixel | 2026-09-26, #310 |
| M3 | A call that moved the headset ends | Returns to the previous holder: immediately if that device has a live trigger, otherwise after the 90s auto-return timeout, and stays if another trigger has since taken it | 2026-09-26, #310 (both modes) |
| M4 | A Meet, Zoom, Teams or Slack call starts on the Mac while the headset is on the Pixel | Moves to the Mac | — |
| M5 | Media starts on one device while neither is playing | Moves to that device | 2026-09-20, #197 |
| M6 | Media starts on device B while device A's media is paused or stopped | Moves to B | — |
| M7 | Manual switch from either device | Moves, and both devices' UI reflect the new holder | 2026-09-26/27, #310 (online half only) |
| M8 | Headset taken out of the case | Goes to the device with an active trigger; if neither has one, to the last holder | — |

## Must not move

| ID | Situation | Expected | Last verified on hardware |
|---|---|---|---|
| N1 | A notification sound or UI sound plays on the non-holder | Stays | — |
| N2 | The holder's media buffers, changes track, or pauses briefly (under the stop debounce) | Stays | — |
| N3 | A VoIP app is open on the non-holder with no call in progress | Stays | — |
| N4 | The holder is on a call (phone or VoIP) and media starts on the other device | Stays | — |
| N5 | Media playing on both devices | Stays wherever it last moved; no bouncing | — |
| N6 | Switching is paused on a device (#290), e.g. the headset is in use by a laptop thrw does not manage | thrw never claims for the paused device and does not fight the user | — |

## Must recover

| ID | Situation | Expected | Last verified on hardware |
|---|---|---|---|
| R1 | The Mac sleeps and wakes; the Pixel dozes | No holder change caused by the sleep itself; correct state within one registration cycle of waking | — |
| R2 | Relay restart, or either device's network drops and returns | Correct holder and route within one registration cycle, with no manual action | 2026-09-20, #197 (reconnect only) |
| R3 | Headset in its case or out of range when a claim is made | Claim resolves `failed` with `target_device_unreachable` quickly, the user is told (#309), and the next valid trigger works normally | — |
| R4 | An adapter crashes or is restarted mid-switch | Recovers to the correct holder without manual action | — |

## Exit criteria for v1

v1 is done when all three hold at the same time, on the same build:

1. Every scenario above passes in the simulator.
2. Every scenario above passes in one scripted hardware pass, recorded
   in `docs/testing/` against a named `adapterVersion`.
3. **14 consecutive days of daily use** on that build with **zero stuck
   states** and **≥ 99% switch success**, computed from persisted
   command outcomes (#207), not from recollection.

## Decisions recorded here (2026-09-28)

- **Media auto-switching is in v1** and has to be reliable, not
  disabled by default. The heuristics behind it may change freely; the
  expected outcomes above may not, without a change to this file.
- **M8:** an active trigger wins; otherwise the last holder.
- **M3:** the auto-return rule as shipped in v0.2.5 stands.
- **Speed** is a v1 goal but not yet an exit criterion. Targets are set
  once per-phase timings exist (Phase 0), because until then we know
  totals (~2.2s release, ~3.3–4.9s claim, ~2.7s with no holder) and not
  where the time goes.
