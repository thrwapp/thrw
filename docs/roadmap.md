# thrw — build roadmap

## How to read this file

Three refreshes in, the pattern is clear enough to state as a rule
rather than re-apologise for each time (#116, #145, #194 — each one's
opening line conceding the last snapshot went stale within days). So:

- **The date stamp is the scope of every status claim below.** Nothing
  here asserts anything about the repo after that date.
- **Where this file and the repo disagree, the repo wins.** Merged
  PRs, the ADRs, and `docs/spec/architecture.md` are authoritative;
  this document is a summary of them and is the thing that is wrong.
- **Work that was in flight at snapshot time names its PR**, so a
  reader can check in one click whether it landed rather than
  inferring from prose.
- **Refresh trigger, not a calendar:** this file is stale the moment
  the "Suggested immediate next step" section's items close. That
  section is what the document is actually used for; when it points at
  closed work, the rest is decoration.

Status snapshot as of **2026-09-28** (adapters v0.2.5): **the product
works on the reference pair and is not yet reliable. The work has moved
from "make it run" to "make it bulletproof across a defined set of
scenarios", and that set now exists: `docs/spec/scenarios.md`.**

The milestone sections below (M1-M10) were last refreshed on 2026-09-20
and are kept for their history and lane assignments. Where they and this
snapshot disagree, this snapshot is the newer summary, and the repo beats
both.

**What works.** A Mac and a Pixel hand AirPods Pro 2 back and forth
through the production relay. #193's pass (recorded in #310,
`docs/testing/compatibility-matrix.md`) verified the call trigger in
both directions (four calls, four clean handovers, a 3.3s claim),
auto-return in both of its modes, and manual claim online, with the
offline half failing shut exactly as ADR 0020 decision 2 requires.
Media-driven switching was verified both ways on 2026-09-20 (#197).
ADR 0018 (reconciliation and idempotency) and ADR 0019 (confirmed
outcomes) are implemented; ADR 0020's coalescing (#279) and Android
reconnect jitter (#305) are in, with decision 2 still open on #277.
Installable builds exist for both platforms (#187-#190 closed), and
every build reports its `adapterVersion` on registration.

**What the last week looked like.** Between 2026-09-22 and 2026-09-27
there were roughly twelve adapter releases, v0.1.1 to v0.2.5, and almost
none of it was new capability. The bugs fell into two groups:

- **Media auto-switching** — #243, #247, #251, #254, #282, #284, #288,
  #295, #298, #303, #304. The media trigger reads audio state that
  thrw's own handover perturbs (the default output device changes, the
  audio gate pauses), so each fix exposed the next case.
- **The relay holding a belief both nodes contradict** — #287, #289,
  #301, #307. Each fix closed one entrance to a wedge and showed another.

Every fix was locally justified, and most commit messages say so
convincingly. The system they add up to is about nine interacting timers
and bounds: the 6s self-cooldown, 2s/4s media start/stop debounce,
3s/6s claim coalescing, 90s/300s stale/gone, two re-asserts per tenure,
90s auto-return, the 8s outcome bound, the 3s unreachable threshold and
#307's stale-fallback release. v0.2.2 and v0.2.3 each shipped a defect
found by hand rather than by any suite, and most of the week's fixes
carry "not verified on hardware". The only loop that finds these bugs is
Tom with the devices, and that is the bottleneck.

**Physical limits** that no fix removes: a switch takes ~2.2s to release
and ~3.3-4.9s to claim, with ~2.7s where nothing holds the headset
(#254); AirPods expose no settable volume, so muting across the handover
does nothing (#304); the only macOS pause mechanism is a play/pause
toggle; the Mac cannot detect phone calls (architecture.md); iPad cannot
move the route at all (#115); Linux does not talk to the relay (#271).

**Not started:** `services/accounts`, `licensing`, `billing`,
`ai-engine` and `telemetry` are still one-line placeholders. Outcomes
reach the relay but are not persisted anywhere (#207), so switch success
rate is not yet a number anyone can read.

## v1 — the goal everything below serves (decided 2026-09-28)

**thrw is headed for a paid product. v1 is the handoff for professionals
who use a Pixel and a Mac: the headset is always on the right device,
moves seamlessly, and gets there as fast as the hardware allows.** The
project is also a deliberate test of agent-driven development, which
shapes the plan below as much as the product does.

- **In scope:** the reference pair, and every scenario in
  `docs/spec/scenarios.md` — including media auto-switching, which has
  to be reliable rather than switched off by default. The heuristics
  behind it may change; the scenario outcomes may not without a change
  to that file.
- **Out of scope until v1 ships:** M4 (iPad, Linux), other headsets,
  HID and focus work, M5 (AI engine), M6/M7 (licensing, billing,
  accounts). The exception is #132's store-account admin, which has lead
  time and costs nothing to start.
- **Done means**, on one build: every scenario passes in the simulator,
  every scenario passes in one scripted hardware pass, and 14
  consecutive days of daily use show zero stuck states and at least 99%
  switch success, computed from persisted outcomes. See the scenario
  file for the definitions of those terms.

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
  interface, or the connection state machine (idle → pre-claim → claim
  → active — ADR 0001, 0010, 0011). Requires a new ADR and human review
  even inside `packages/**`, never a routine agent PR. Since ADR 0015
  and ADR 0016 this also covers the topic structure's resource-type
  segment and the focus topic, and since ADR 0018/0019 the command
  sequence number and the confirmed-outcome shape of claim/release —
  see AGENTS.md's protocol-invariants section for the current list.

  **Four states, not five.** This section previously listed `cooldown`
  as a fifth state, contradicting M1 item 2 below in the same document.
  ADR 0013 settled it: cooldown is an adapter-local suppression window,
  not a lifecycle stage the relay or other nodes observe.
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

**Still open**: nothing for this milestone's own scope, and the relay is
now genuinely reachable by an adapter (#147). Two operational issues sit
just outside it: `deploy.yml` breaks permanently if anyone ever deploys
manually, via stale `/tmp` files (#180), and CODEOWNERS was not actually
enforcing the human-merge rule (#181, fixed by #195's `codeowners-gate`
job — now a required check with no bypass). Neither is
milestone scope; both will bite during hardware testing, when the relay
gets redeployed.

## M3 — First real adapter pair (Android + Mac) — first real handoff achieved; blocked on having no installable build

This is the actual product demo: cross-device handoff working on real
hardware. Agent auto-merge lane for the code; **real-hardware validation
is human-only** (no Bluetooth in CI) — every M3 PR's tests are necessarily
mocked/simulated at the OS-API boundary, and "done" per AGENTS.md still
needs a follow-up manual QA pass against Tom's actual AirPods + Pixel
before it's trusted.

Both adapters are code-complete for a first handoff and can now reach
the production broker: #147 closed the credential gap that this section
previously named as the blocker, by way of a gitignored
`config/adapter.local.properties` overlay per adapter (ADR 0005).

**The milestone's goal has now happened at least once.** #197 records a
real media-driven handoff in both directions against `relay.thrw.app`,
on the reference hardware, with route evidence on each side — the first
time this product did the thing it exists to do outside a test double.

**What blocks it being a daily-usable product is not adapter logic.**
#182 is fixed (#192). What remains is that there is no artifact to
install on either device: the
Android release path produces an AAB, which Play accepts and a phone
cannot (#188); the Mac has no packaged `.app` from CI at all (#189);
and a CI-built release of either would carry empty credentials (#187).
Those four are tracked under M10, not here, because they are
distribution work rather than adapter work — but they are what stands
between this milestone and its own goal. #193 is the QA pass itself.

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
   stops reaping it (#142). Media-playback detection via
   `MediaSessionManager` followed (#165/#168), then three real-device
   fixes that unit tests could not have caught: a `Handler` created on a
   Looper-less thread killing the media trigger at startup, a session
   recreation leaving it deaf (#174/#175/#176), an MQTT connect hanging
   forever on-device (#158), an uncaught Bluetooth error crashing the
   adapter (#161), and an RFCOMM socket that could not move the audio
   route (#162). Substantially complete as code, and now able to reach
   the production relay (#147) — still unverified against real hardware
   beyond ad-hoc manual runs.
2. ✅ `packages/adapter-mac`: now at parity with Android for a first
   handoff. Bluetooth connect/disconnect via `IOBluetooth`, not
   `CoreBluetooth` (#95, corrected by #101 after CoreBluetooth turned out
   to be BLE-only and unable to move the audio route); the node interface
   over real MQTT (#112 — `MacNode`, `MQTTNIOTransport`, `RelayConfig`
   via a SwiftPM build-tool plugin); trigger detection (#127); a menu-bar
   composition root (#128); a provisioning UI with a paired-device picker
   (#143); heartbeats (#142); Open at Login (#144); and media-playback
   detection via CoreAudio (#166/#169).

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
   gaps are closed. The relay side has since grown two recovery
   behaviours this item predates: re-claiming for a node that restarts
   while it holds the resource (#173/#177), and treating every
   registration as a repeatable statement of current state so a relay
   that lost its picture recovers on its own (#178/#185).

   Real cross-language hardware validation remains outstanding
   (human-only, per this section's own note above) — #193.

   Real-world data points exist and are accumulating: during #143 a
   provisioned Mac app published a genuine registration and a real
   `voip` event from #127's monitor, and the measurements behind #186
   came from running both adapters against the reference devices — the
   audio route staying on the Mac's own speakers while Bluetooth still
   reported the AirPods as connected, a claim taking 3-5s to settle,
   and a media monitor re-firing at +4s and +5s. That kind of evidence
   has now corrected three ADR decisions that read fine on paper.

## M4 — Remaining adapters (iPad, Linux)

Same node interface, lower priority than M3 since they don't unblock the
first demo. Agent auto-merge lane once the M3 pattern is proven and can be
pointed to as precedent.

**Sequencing note (AGENTS.md).** Peripheral (HID) adapter work and
further focus-tracking work — the natural next feature surface, per ADR
0015's `hid` resource type and ADR 0016's focus topic — are gated behind
two things: the ADR 0015 topic migration (#171), and the reliability
ADRs 0018-0020 being implemented and verified against the existing
Mac/Pixel pair. Both guarantees get harder to retrofit with every
resource type and adapter layered on top, which is the whole reason for
the ordering. The iPad and Linux adapters below are not affected — they
are the same `audio` resource type on new platforms, not a new resource
type.

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

**Scope is wider than latency since ADR 0019.** Every claim and release
must resolve to a confirmed outcome — succeeded, failed with a reason
code, or timed out — reported unconditionally, so switch success rate
is a measured number rather than inferred from the absence of
complaints. Broken down by resource type, platform pairing and device
model, that is also the only way hardware-specific failure patterns
become visible without manually reproducing them, which makes it the
precondition for `docs/testing/compatibility-matrix.md` holding
anything but manual test dates. ADR 0018's reconciliation-mismatch
metric feeds the same pipeline.

## M9 — Proactive conflict resolution (ADR 0012)

Detecting and helping resolve *other* connection managers competing for
the same headset (e.g., the OS's own Bluetooth settings, another vendor's
app). Deferred — needs a working baseline (M1-M3) to even observe
conflicts against.

## M10 — Distribution

Two different problems that this section used to treat as one. Getting a
build onto Tom's own two devices is near-term, mostly agent-doable, and
currently on the critical path; getting a build into a store is neither.

**M10a — internal test builds (now).** The immediate goal: an
installable build of each app that Tom can run for a few days on the
reference hardware. Four gaps, none of them adapter code:

- #187 — a CI-built release ships with empty relay credentials and is
  rejected at connect. `release-android.yml` injects keystore secrets
  and nothing else.
- #188 — the Android release path produces an `.aab`, which is an
  upload format Play expands into APKs; it cannot be sideloaded.
- #189 — the Mac has no packaged `.app` from CI at all.
  `Scripts/build-app-bundle.sh` assembles one correctly but says in its
  own header that it is for a human building locally, and nothing calls
  it. `release.yml`'s `mac` job is still a placeholder echoing a TODO
  into a text file.
- #190 — `release.yml` and `release-android.yml` both fire on `v*` tags
  and both attach assets to the same Release, so a placeholder text
  file lands next to a real signed bundle.

Signing is where M10a touches M10b: #132's Apple enrollment and the
`app.thrw.mac` bundle ID are done, so Developer ID signing is now
available if the unsigned "Open Anyway" path proves annoying in daily
use. For one Mac, unsigned is probably enough — and the friction, if it
appears, is itself the signal.

**M10b — store submission (later).** App Store / Play Store listings,
code signing for public distribution, release packaging. Human-only;
`release.yml` and `scripts/social-post.py` are scaffolded for the
announcement side, but store submission isn't something an agent can
complete (developer account actions, signing keys, human sign-off on
listings). #132 tracks the account and listing work, and notes the
blocking dependency both stores share: a live privacy-policy URL.

A shared relay credential compiled into the binary is fine for M10a and
explicitly not fine for M10b, which needs per-device credentials from
`services/accounts` (M7). `config/adapter.properties` says so in its own
comment.


## Suggested immediate next step

This section is what the document is used for, and it goes stale when
its items close (see the reading rule at the top). As of 2026-09-28 it
is the v1 plan, in phases. Phase issues are to be opened against this
text; until they exist, the phase names below are the reference.

**The change of method matters more than any single phase.** Until now,
bugs were found by hand, fixed against mocks and shipped. From here, a
bug is reproduced as a failing scenario (`docs/spec/scenarios.md`)
before it is fixed, and hardware is where a fix is confirmed, not where
it is first discovered. That is also the only version of agent-driven
development that can be tested: an agent that can run the scenarios can
observe what it is changing.

### Phase 0 — spec and measurement

1. **The scenario set** — `docs/spec/scenarios.md`, landed with this
   refresh. Every later phase is judged against it.
2. **Per-phase switch timings.** ADR 0019's outcomes carry one
   `durationMs`; Phase 3 needs where that time goes: relay dispatch,
   node receipt, Bluetooth connect accepted, profile connected, route
   observed. Adding fields to the outcome payload touches the frozen
   confirmed-outcome shape, so this is an ADR 0019 amendment first,
   human-merged, then the implementation. Optional fields only, so older
   builds stay valid.
3. **#207 — persist outcomes somewhere readable.** The v1 exit criterion
   is a computed success rate over 14 days; relay logs that die on
   redeploy cannot produce it. The smallest thing that works (outcome
   events appended to durable storage, one query to compute the rate per
   scenario class) beats the full M8 service.

### Phase 1 — a deterministic simulator

The key investment, and the one the agent-driven-development goal
depends on. `packages/testkit` is still a placeholder; this is its job.

- A virtual clock; fake Bluetooth with latencies drawn from measurement
  (#254's release and claim figures, #257's accepted-versus-connected
  gap); fake audio signals **including thrw's own perturbations** — the
  ~0.5s `DeviceIsRunningSomewhere` gap when the default output changes
  (#298), the audio gate's pause (#295), Spotify's periodic buffering
  (#288), a checked continuation that never resumes (#303).
- The real `relay-core` and `relay-hosted` decision logic runs inside
  it unmodified.
- **The open design question:** the adapters' trigger and debounce
  logic is Swift and Kotlin, and a TypeScript simulator cannot run it.
  The options are (a) scenarios as language-neutral fixtures (JSON
  signal traces plus expected outcomes) that the TS relay simulator and
  each adapter's own test suite all consume, or (b) modelling adapter
  behaviour in TS, which drifts. (a) is the likely answer; Phase 2's
  question about where debouncing belongs may make it simpler, if
  adapters end up reporting raw signals and the relay decides.
- Every scenario becomes a simulator test, and every past bug with a
  trace (#251, #288, #295, #298, #303, #307 at minimum) becomes a
  regression case. **Expectation: several scenarios fail on v0.2.5
  before anything is changed.** That is the point; it is the backlog.

### Phase 2 — better heuristics, fewer timers

Driven by whatever Phase 1 shows failing, but three things are already
clear:

- **Per-process audio detection on macOS.** The Mac's media trigger
  watches the *default output device*, which thrw itself changes on
  every handover — the root of #298, #295 and #303. Recent macOS exposes
  per-process audio state that does not depend on which device is the
  default; a spike should confirm it is readable without a TCC grant and
  that it behaves on the reference Mac. If it does, it removes the cause
  rather than debouncing the symptom.
- **User actions as the primary signal, audio state as secondary.**
  Pressing play, answering a call, a manual claim and unlocking a device
  are intent; "audio is flowing" is evidence, and noisy evidence.
- **One arbitration model in place of the scattered timers**, written as
  a new ADR (it changes frozen contract, so human review) and validated
  against the full scenario set in the simulator. It should decide where
  debouncing lives, adapter or relay. Success is fewer mechanisms, not
  more.

Folds in #304 (macOS suppression is inert on AirPods), #308 and #309
(UI truth and failure feedback, needed for M7 and R3), #277's open
decision 2, and #183 if it recurs.

### Phase 3 — speed

- **Claim on ring, not on answer** (ADR 0021's executing pre-claim) —
  a call rings for several seconds, so M1's switch time can largely
  disappear. This is the biggest available win and it is for the
  highest-priority trigger.
- **Profile ordering**, using Phase 0's timings: connect the call
  profile first for calls and the media profile first for media, and
  measure rather than assume.
- **Targets are set after measurement.** Media cannot hide latency the
  way a ringing call can, so there is a floor, and the honest thing is
  to find it before promising a number.

### Phase 4 — soak, then v1 distribution

- #193 becomes the **scripted** hardware pass: every scenario, on one
  named `adapterVersion`, recorded in `docs/testing/` with
  `scripts/qa-capture.sh` running throughout.
- The 14-day run on that build, judged only by #207's numbers.
- Then distribution: Play internal testing and a Developer-ID-signed,
  notarised Mac build (#132, M10b), and M7/M6 after that.

**Explicitly deferred**, however ready they look: #271 (Linux), the iPad
bootstrap, #274 (site content), #287's unmanaged-device detection beyond
the pause control that already ships, and anything under M5-M7.
