# thrw — build roadmap

Status snapshot as of 2026-09-18, later the same day (the previous
snapshot — itself written on 09-18 to replace a stale 09-15 one — was
overtaken within hours by the work it was describing): **both adapters
are now code-complete for a first handoff, and the blocker is no longer
missing adapter code.**

M1 (protocol + relay-core) is fully built and tested.
`packages/adapter-android` is a substantially complete node — Bluetooth
Classic connect/disconnect, the node interface over real MQTT, call/VoIP
trigger detection, a foreground `Service` composition root, a
provisioning UI with a bonded-device picker, and heartbeats (#142).
`packages/adapter-mac` has now caught up: real classic-Bluetooth
connect/disconnect via `IOBluetooth` (#95, corrected by #101), the node
interface over real MQTT (#112), VoIP trigger detection (#127), a
menu-bar composition root (#128), a provisioning UI with a paired-device
picker (#143), and heartbeats (#142). `packages/adapter-linux` has a
bootstrapped BlueZ connection seam (#108), one stage behind where
adapter-mac was before #112. `packages/adapter-ipad` is still a bare
skeleton and, per #115's research, faces a real platform ceiling (below).

`services/relay-hosted` is done for this stage: a live EMQX broker on GCP
(#80/#81), TLS termination (#119), and #118's real
`PriorityEngine`/`DeviceRegistry` process actually deployed alongside it
and verified end-to-end against `relay.thrw.app` (#129). Every other
service (`licensing`, `billing`, `accounts`, `ai-engine`, `telemetry`)
remains a one-line placeholder, genuinely not started.

**What now blocks a real demo is #147**: neither adapter can send MQTT
credentials at all, while the deployed broker runs `allow_anonymous =
false`. So no adapter can connect to production, which also means #128,
#142 and #143 have only ever been verified against local/anonymous
brokers — never the real relay. See "Suggested immediate next step".

This document breaks the remaining work into milestones and states, for
each one, which pipeline lane it runs through.

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

## M2 — Relay hosted service (services/relay-hosted) — ✅ done for this stage

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

✅ Both items this section previously listed as "still open" have since
landed. #118's process is deployed on the relay VM as a third container
alongside `relay` and `caddy`, built and rolled by `deploy.yml` +
`scripts/relay-redeploy.sh` (#129) — verified for real, not just
deployed: a live MQTT client published a registration and a `call` event
to `relay.thrw.app` and received a genuine CLAIM back. TLS termination
for the broker's WebSocket listener is done too, via Caddy in front of
EMQX (#119), which is why adapters point at `wss://relay.thrw.app/mqtt`.

**Still open**: nothing for this milestone's own scope. The relay is not,
however, actually reachable *by an adapter* — see #147 under M3.

## M3 — First real adapter pair (Android + Mac) — both adapters code-complete, blocked on #147

This is the actual product demo: cross-device handoff working on real
hardware. Agent auto-merge lane for the code; **real-hardware validation
is human-only** (no Bluetooth in CI) — every M3 PR's tests are necessarily
mocked/simulated at the OS-API boundary, and "done" per AGENTS.md still
needs a follow-up manual QA pass against Tom's actual AirPods + Pixel
before it's trusted.

Both adapters are now code-complete for a first handoff. **The blocker is
#147, not missing adapter code and not (yet) the manual QA pass**:
neither adapter can send MQTT credentials, and the deployed broker runs
`allow_anonymous = false`, so an adapter pointed at `relay.thrw.app`
fails at connect with `badUserNameOrPassword`. Found by actually running
a provisioned Mac app against production during #143. Until #147 lands,
the manual QA pass cannot even be attempted, and every adapter-side
claim in this milestone is verified only against a local anonymous
broker.

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
   replacing free-text address entry (#117), and heartbeats so the relay
   stops reaping it (#142). Substantially complete as code; unverified
   against real hardware, and unable to reach the real relay (#147).
2. ✅ `packages/adapter-mac`: now at parity with Android for a first
   handoff. Bluetooth connect/disconnect via `IOBluetooth`, not
   `CoreBluetooth` (#95, corrected by #101 after CoreBluetooth turned out
   to be BLE-only and unable to move the audio route); the node interface
   over real MQTT (#112 — `MacNode`, `MQTTNIOTransport`, `RelayConfig`
   via a SwiftPM build-tool plugin); trigger detection (#127); a menu-bar
   composition root (#128); a provisioning UI with a paired-device picker
   (#143); and heartbeats (#142). Open at Login (#144) is in flight.

   **Trigger detection is deliberately narrower here than on Android**,
   and permanently so: this item previously described it as
   "`AVAudioSession` + process watching", but #127 established that
   **`AVAudioSession` does not exist on macOS** (it is iOS/tvOS/watchOS
   only) and that macOS exposes no call-detection API to third-party apps
   at all. So the Mac adapter detects VoIP by process watching and
   **cannot detect phone calls** — architecture.md's rule 1 is
   unimplementable on this platform. See `docs/spec/architecture.md`'s
   "Mac's trigger-detection gap" section.
3. ✅ (in spirit) Integration: `packages/relay-core/test/handoff-integration.test.ts`
   (#113/#114) proves a simulated Android-shaped node and a simulated
   Mac-shaped node drive a real claim/release/auto-return cycle through
   real `PriorityEngine`/`RelayMqttClient` over a real broker - the thing
   this item asked for, just simulated at the relay-core layer rather
   than through two real running adapter processes. `services/relay-hosted`'s
   live process is now actually deployed (#118 + #129, M2), and item 2's
   gaps are closed, so a real end-to-end path - two real adapters talking
   to the real relay - is blocked only on **#147** (adapters cannot
   authenticate). Real cross-language hardware validation remains
   outstanding after that (human-only, per this section's own note above).

   One real-world data point already exists: during #143 a provisioned
   Mac app, pointed at a local broker, published a genuine registration
   *and* a real `voip` event produced by #127's monitor detecting an
   actually-running VoIP app. That is the first time the Mac trigger path
   ran outside a unit test.

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

Both adapter-mac gaps this section used to name are closed (#127, #128),
along with provisioning (#143) and heartbeats (#142). The previous
version of this section pointed entirely at work that is now done.

**The next step is #147: give the adapters MQTT credentials.** Nothing
else on the critical path can be verified until it lands. The deployed
broker runs `allow_anonymous = false`, and neither
`MQTTNIOTransport.connect` nor `HiveMqttTransport` accepts a username or
password — so a fully provisioned adapter fails at connect, and #128,
#142 and #143 have only ever been exercised against local anonymous
brokers. #147 carries the real design question with it (a shared
build-time credential is easiest but bakes a secret into every
distributed binary; per-device credentials need `services/accounts`,
which is M7 and unstarted), so it wants a decision, not just an
implementation.

**Then** the long-known human-only step becomes reachable for the first
time: a manual QA pass against Tom's actual AirPods + Pixel + Mac,
against the already-live relay. Both adapters are code-complete for it,
and `services/relay-hosted` is deployed and verified (#129) — so after
#147 there is genuinely nothing left between here and attempting the
first real cross-device handoff.

Worth noting what that QA pass will be the first real test of: every
adapter-side behaviour in M3 is currently verified against fakes or a
local broker only. Bluetooth in particular has never run in CI at all
(no hardware), so `IOBluetoothPeripheralGateway`'s and
`AndroidBluetoothClassicGateway`'s real connect/disconnect paths are
entirely unexercised outside manual use.

Lower-priority, but each unblocked and ready to scope whenever it's
prioritized: `packages/adapter-linux`'s node-interface/MQTT wiring
(mirroring #112's own shape, one milestone behind where Mac just got to),
and `packages/adapter-ipad`'s now-scoped bootstrap (#115 answered the
open question — an issue can be written today around "observe + prompt,"
not "connect/disconnect").
