# thrw — build roadmap

Status snapshot as of 2026-09-18 (the 09-15 snapshot below went stale
within days — governance/CI/CD proved out fast, and the packages/services
work moved faster still): the "none of the actual product exists yet"
framing is no longer true. M1 (protocol +
relay-core) is fully built and tested. `packages/adapter-android` is a
substantially complete node — Bluetooth Classic connect/disconnect, the
node interface over real MQTT, call/VoIP trigger detection, a foreground
`Service` composition root, and a provisioning UI with a bonded-device
picker. `packages/adapter-mac` has real classic-Bluetooth connect/disconnect
(via `IOBluetooth`, not `CoreBluetooth` — see #101) and, as of #112, the
node interface wired over real MQTT too; it still needs a composition
root and trigger detection to reach parity with Android. `packages/adapter-linux`
has a bootstrapped BlueZ connection seam (#108), one stage behind
adapter-mac's own trajectory. `packages/adapter-ipad` is still a bare
skeleton, and per #115's research, faces a real platform ceiling (below).
`services/relay-hosted` has a live EMQX broker deployed to GCP (#80/#81)
and, as of #118, an actual `PriorityEngine`/`DeviceRegistry` process
subscribing to it — production deployment wiring for that process is a
documented, deliberate follow-up, not done yet. Every other service
(`licensing`, `billing`, `accounts`, `ai-engine`, `telemetry`) remains a
one-line placeholder, genuinely not started. This document breaks the
remaining work into milestones and states, for each one, which pipeline
lane it runs through.

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

## M1 — Protocol & relay core (packages/protocol, packages/relay-core) — ✅ done

The foundation everything else depends on. Agent auto-merge lane, per the
nuance above, as long as each issue's acceptance criteria quote the exact
spec from architecture.md rather than inventing new shapes. All four items
below are merged; `packages/relay-core`'s own priority-engine logic has
since been proven end-to-end against a real broker too (#113/#114, M3.3
below).

1. ✅ `packages/protocol`: node-interface types (`NodeInterface`,
   `NodeManifest`, `EventKind`), MQTT topic builders, and `TopicQos` —
   `packages/protocol/src/index.ts` (#30).
2. ✅ `packages/protocol`: connection state machine (idle → pre-claim →
   claim → active, ADR 0013's four states, no fifth "cooldown") —
   `ConnectionStateMachine`/`LEGAL_TRANSITIONS` in the same file (#54),
   unit-tested against every legal and illegal transition
   (`packages/protocol/test/index.test.ts`).
3. ✅ `packages/relay-core`: `RelayMqttClient` (#65) and `DeviceRegistry`
   (#62) — the registry holds nothing about a node beyond what its
   manifest declared, per architecture.md. `RelayMqttClient` has since
   grown a generic events-topic subscription (`subscribeAllEvents`, #97)
   beyond this milestone's original single-heartbeat scope.
4. ✅ `packages/relay-core`: `PriorityEngine` — all 5 ordered rules (call
   > manual claim > VoIP > media > last-claimed) plus the `call_ended`
   auto-return timeout (default 90s) — #43.

## M2 — Relay hosted service (services/relay-hosted) — mostly done

Human-merge lane (`services/**`). This section's own text was stale as of
#116's research (it described the EMQX deployment as future work; it's
been live since #80/#81) — updated here per that issue's own allowance to
fix factually-wrong M2 text found along the way, not rewritten wholesale.

✅ The EMQX broker itself is built, configured (ADR 0006: GCP Compute
Engine, not Fly.io/Cloud Run) and deployed to a live GCP VM — `Dockerfile`/
`emqx.conf`/`acl.conf`/`docker-entrypoint-relay.sh` (#80/#81), wired into
`deploy.yml` + `scripts/health-check-or-rollback.sh`, debugged live post-
deploy (#92/#93).

✅ `relay-core`'s `PriorityEngine`/`DeviceRegistry` now actually runs
against that broker as a real process, not just against a simulated pair
of nodes — `services/relay-hosted/src/relay-service.ts` (#118),
per-account subscription via `RelayMqttClient.subscribeAllEvents`,
tested against a real local broker and verified end-to-end with a real
`docker build`/`docker run`.

**Still open**: wiring #118's process into the *actual* production
deploy pipeline (`deploy.yml` currently builds/runs only the EMQX
container; running the new process alongside it on the relay VM is a
deliberate, documented follow-up — see `docs/handoffs/118.md`), and TLS
termination for the broker's WebSocket listener (plaintext today; #119
tracks this, gated on a real domain + cert existing first).

## M3 — First real adapter pair (Android + Mac) — Android substantially done, Mac in progress

This is the actual product demo: cross-device handoff working on real
hardware. Agent auto-merge lane for the code; **real-hardware validation
is human-only** (no Bluetooth in CI) — every M3 PR's tests are necessarily
mocked/simulated at the OS-API boundary, and "done" per AGENTS.md still
needs a follow-up manual QA pass against Tom's actual AirPods + Pixel
before it's trusted. That manual QA pass is now the main thing actually
blocking a real demo, not missing code — see item 2 below for the one
real code gap left.

The blocking prerequisite this section used to name (a placeholder
"Reference hardware" section) is resolved for Android/Mac:
`docs/spec/architecture.md`'s "Reference hardware" section now names
AirPods Pro 2, Pixel 10 Pro, and MacBook Air 13" M4 2025. (iPad's
reference hardware is still unspecified —
see M4 below, a real but separate gap.)

1. ✅ `packages/adapter-android`: the node interface, fully wired -
   Bluetooth Classic connect/disconnect (#74), MQTT transport + node
   interface (#83), call/VoIP trigger detection via `TelephonyManager`/
   `NotificationListenerService` (#86), a foreground `Service`
   composition root actually instantiating all of it (#96), a
   provisioning UI for account id + runtime permissions (#102) and
   notification-listener access (#109), and a bonded-device picker
   replacing free-text address entry (#117). Substantially complete as
   code; unverified against real hardware (see above).
2. 🚧 `packages/adapter-mac`: the node interface - Bluetooth connect/
   disconnect via `IOBluetooth`, not `CoreBluetooth` (#95, corrected by
   #101 after CoreBluetooth turned out to be BLE-only and unable to move
   the audio route), and, as of #112, the node interface wired over real
   MQTT (`MacNode`, `MQTTNIOTransport`, `RelayConfig` via a SwiftPM
   build-tool plugin). **Still missing, to reach parity with Android**: a
   composition root (Mac's own equivalent of #96 - nothing constructs a
   real `MacNode`/connects it yet) and trigger detection
   (`AVAudioSession` + process watching - no `triggers/`-equivalent
   package exists for Mac yet). Neither has an issue filed yet as of this
   writing.
3. ✅ (in spirit) Integration: `packages/relay-core/test/handoff-integration.test.ts`
   (#113/#114) proves a simulated Android-shaped node and a simulated
   Mac-shaped node drive a real claim/release/auto-return cycle through
   real `PriorityEngine`/`RelayMqttClient` over a real broker - the thing
   this item asked for, just simulated at the relay-core layer rather
   than through two real running adapter processes (which adapter-mac's
   gaps above still block). `services/relay-hosted`'s new live process
   (#118, M2) means a real end-to-end path - two real adapters talking to
   a real relay - is now only blocked on item 2 above, not on relay-core
   itself. Real cross-language hardware validation is still outstanding
   (human-only, per this section's own note above).

## M4 — Remaining adapters (iPad, Linux)

Same node interface, lower priority than M3 since they don't unblock the
first demo. Agent auto-merge lane once the M3 pattern is proven and can be
pointed to as precedent.

- 🚧 `packages/adapter-linux` (BlueZ + PulseAudio/D-Bus, Rust): bootstrap
  done - a BlueZ-backed Bluetooth connection seam (#108), the same stage
  `packages/adapter-mac` was at after #95, before its own node-interface/
  MQTT wiring (#112). Node interface + trigger detection (PulseAudio/
  D-Bus) still ahead of it.
- ⚠️ `packages/adapter-ipad` (originally scoped as CallKit + CoreBluetooth):
  still a bare SwiftPM skeleton, and per #115's research, faces a real
  platform ceiling before any bootstrap work should start - iPadOS has no
  public API (CoreBluetooth included - it's BLE-only there too, same as
  Mac) that lets a third-party app force which device a classic-profile
  Bluetooth audio accessory is connected to. See
  `docs/spec/architecture.md`'s "iPad's Bluetooth audio-route limitation"
  section for the full finding and citations. Practical effect on this
  milestone: `adapter-ipad`'s node interface can *observe* the route and
  detect trigger events (CallKit still applies for call detection) but
  cannot execute `on_claim`/`on_release` automatically - its acceptance
  criteria need to be scoped around "prompt the user to switch manually,"
  not "connect/disconnect," which is a real product-behavior difference
  from the other three adapters, not just an implementation detail.

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

M1 is done; the pipeline itself, and this document, moved past "start M1"
days ago. The most direct path to M3's actual goal — cross-device handoff
working on real hardware — is closing `packages/adapter-mac`'s two
remaining gaps (M3 item 2 above): a composition root (mirroring
`adapter-android`'s #96 — nothing constructs a real `MacNode` yet) and
trigger detection (`AVAudioSession` + process watching, mirroring
`adapter-android`'s `triggers/` package). Both are agent auto-merge lane,
`packages/**` work with real precedent to cite (#96 for the composition
root's shape, #86 for how trigger monitors wire into `EventLifecycle`).
Once both land, the real blocker becomes M3's already-known human-only
step: a manual QA pass against Tom's actual AirPods + Pixel + Mac,
including wiring `services/relay-hosted`'s new live process (#118) into
an actual reachable deployment for that test to run against (M2's own
still-open item).

Lower-priority, but each unblocked and ready to scope whenever it's
prioritized: `packages/adapter-linux`'s node-interface/MQTT wiring
(mirroring #112's own shape, one milestone behind where Mac just got to),
and `packages/adapter-ipad`'s now-scoped bootstrap (#115 answered the
open question — an issue can be written today around "observe + prompt,"
not "connect/disconnect").
