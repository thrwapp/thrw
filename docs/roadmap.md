# thrw — build roadmap

Status snapshot as of 2026-09-15: governance, CI/CD, and the fully agentic
issue→PR→eval→merge pipeline are proven end-to-end (issue #24 → PR #25).
Every package and service under `packages/**` and `services/**` is still a
one-line placeholder (`export const xPackageName = "@thrw/x";`) or, for the
native adapters, a single constant. **None of the actual product exists
yet.** This document breaks that remaining work into milestones and states,
for each one, which pipeline lane it runs through.

## Pipeline lanes (recap from AGENTS.md)

- **Agent auto-merge** — `packages/**` work with no frozen-contract change.
  Opens via an `agent-ready`-labeled issue, flows through
  `agent-code.yml` → `agent-eval.yml` with no human touching it, assuming
  the evaluator passes.
- **Human-merge, agent-authored** — `services/**` (FSL, ADR 0003) and
  anything under `.github/**`, `docs/adr/**`, or a `pricing` path. An
  agent can still write the PR; a human (CODEOWNERS: `@Hawk94`) must merge
  it.
- **ADR-gated** — any change to the MQTT topic structure, the node
  interface, or the connection state machine (idle/pre-claim/claim/active/
  cooldown — ADR 0001, 0010, 0011). Requires a new ADR and human review
  even inside `packages/**`, never a routine agent PR.
- **Human-only** — real hardware validation, app store submission, code
  signing, anything needing a physical AirPods/Pixel/Mac in the loop. Not
  agent-doable at all; CI has no Bluetooth hardware.

An important nuance for issue-writing: **implementing** the node interface
and state machine for the first time, exactly as ADR 0001/0010/0011
already specify them, is not a "change" to the frozen contract — it's
fulfilling it, and can go through the normal agent auto-merge lane. Only a
*deviation* from the spec (new topic shape, new state, changed transition)
needs a new ADR. Every M1 issue below should say this explicitly, or an
evaluator/triage agent may reflexively flag it as touching a frozen
contract and stop.

## M1 — Protocol & relay core (packages/protocol, packages/relay-core)

The foundation everything else depends on. Agent auto-merge lane, per the
nuance above, as long as each issue's acceptance criteria quote the exact
spec from architecture.md rather than inventing new shapes.

1. `packages/protocol`: wire types for the node interface —
   `register(manifest)`, `emit_event(type, priority)`, `on_claim()`,
   `on_release()` — and the MQTT topic strings (`thrw/{account}/nodes/
   {node}/events`, `.../commands/{node}`, `.../state`, `.../heartbeat`).
   TypeScript types + a small serialization/validation layer. This is what
   every adapter and the relay both import, so it should ship before
   anything else in M1-M3.
2. `packages/protocol`: connection state machine (idle → pre-claim → claim
   → active, per architecture.md and ADR 0013 — cooldown is adapter-local,
   not a fifth state here) as a typed state container with the transition
   rules from ADR 0010/0011, unit-tested against every legal and illegal
   transition.
3. `packages/relay-core`: MQTT client wrapper (QoS 1 for events/commands,
   QoS 0 heartbeat, retained state topic) and device/capability registry —
   holds nothing about a node beyond what its manifest declared.
4. `packages/relay-core`: priority rules engine — the 5 ordered rules from
   architecture.md (call > manual claim > VoIP > media > last-claimed) plus
   the auto-return timeout after `call_ended` (default 90s, later tunable
   by `services/ai-engine`).

## M2 — Relay hosted service (services/relay-hosted)

Human-merge lane (`services/**`). Wraps `relay-core` in an actual
deployable EMQX-backed service per ADR 0006 (GCP Compute Engine, not
Fly.io/Cloud Run), wired into the already-scaffolded `deploy.yml` +
`scripts/health-check-or-rollback.sh`. Needs real GCP infra decisions
(networking, EMQX config, TLS termination) that should go through a human
first pass rather than a cold agent issue.

## M3 — First real adapter pair (Android + Mac)

This is the actual product demo: cross-device handoff working on real
hardware. Agent auto-merge lane for the code; **real-hardware validation
is human-only** (no Bluetooth in CI) — every M3 PR's tests are necessarily
mocked/simulated at the OS-API boundary, and "done" per AGENTS.md still
needs a follow-up manual QA pass against Tom's actual AirPods + Pixel
before it's trusted.

Blocking prerequisite: the "Reference hardware" section in
`docs/spec/architecture.md` is still a placeholder — needs Tom's exact
AirPods generation, Pixel model, and Android version before M3 acceptance
criteria can cite real OS API versions/behavior.

1. `packages/adapter-android`: implement the node interface — Bluetooth
   Classic connect/disconnect (no root, no VendorID spoofing — ADR 0002),
   `TelephonyManager` + `NotificationListenerService` for call/VoIP
   trigger detection, Kotlin coroutines per AGENTS.md.
2. `packages/adapter-mac`: implement the node interface — CoreBluetooth
   connect/disconnect, `AVAudioSession` + process watching for trigger
   detection, Swift 6 concurrency per AGENTS.md.
3. Integration issue (likely `model:opus`, since it touches two adapters'
   platform APIs and the triage heuristic in `agent-triage.yml` routes
   platform-API adapter work to Opus automatically): end-to-end mocked
   handoff test — simulated call-start on the Android side correctly
   drives a claim/release cycle observed by the Mac side through
   `relay-core`.

## M4 — Remaining adapters (iPad, Linux)

Same node interface, lower priority than M3 since they don't unblock the
first demo. `packages/adapter-ipad` (CallKit + CoreBluetooth),
`packages/adapter-linux` (BlueZ + PulseAudio/D-Bus, Rust). Agent auto-merge
lane once the M3 pattern is proven and can be pointed to as precedent.

## M5 — AI engine (services/ai-engine)

Per-user auto-return timeout learning (replacing the flat 90s default),
routed through Vertex AI per ADR 0008 (model choice by task difficulty).
Human-merge lane. Depends on M1's priority rules engine existing first and
on `services/telemetry` (M8) existing to supply the training signal, so
sequence this after both, not before.

## M6 — Licensing & billing (services/licensing, services/billing)

Per ADR 0009: self-hosted Keygen CE for device-limit licensing
(Free=1/Pro=3/Teams=pooled, offline validation caching), Stripe for
subscriptions, decoupled via a webhook bridge (Stripe lifecycle events →
Keygen API calls). Human-merge lane, and per AGENTS.md, no build-time
endpoint may be hardcoded (ADR 0005) — every adapter must read the
licensing endpoint from its own build-time config file. Not urgent until
there's a working product to license.

## M7 — Accounts (services/accounts)

Ties a user identity to their licensed devices and relay account scope
(the `{account}` prefix in every MQTT topic). Human-merge lane. Needed
before M6 can mean anything (licensing needs an account to attach to).

## M8 — Telemetry (services/telemetry)

Needed to validate the latency numbers architecture.md explicitly flags
as unvalidated (2-4s typical, 3.5-4s p95 alert threshold) against real
hardware, and per ADR 0007 to decide if/when a second region is
justified. Human-merge lane. Should land alongside or just after M3 so
there's real handoff activity worth measuring.

## M9 — Proactive conflict resolution (ADR 0012)

Detecting and helping resolve *other* connection managers competing for
the same headset (e.g., the OS's own Bluetooth settings, another vendor's
app). Deferred — needs a working baseline (M1-M3) to even observe
conflicts against.

## M10 — Distribution

App Store / Play Store submission, code signing, release packaging. Human-
only; `release.yml` and `scripts/social-post.py` are already scaffolded
for the announcement side, but store submission itself isn't something an
agent can complete (developer account actions, signing keys, human
sign-off on store listings).

## Suggested immediate next step

Start M1 now — it's pure `packages/**`, no external infra or hardware
dependency, and directly exercises the pipeline we just proved end-to-end
on a real (if small) piece of the actual product instead of a throwaway
`sleep()` helper. Suggest opening the 4 M1 issues above via the
`agent-task.yml` template, one at a time (protocol types before relay-core,
since relay-core imports them), each explicitly citing the architecture.md
section it implements so the evaluator has something concrete to check
citations against.
