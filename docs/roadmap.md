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

Status snapshot as of **2026-09-20**: **both adapters are
code-complete, can now reach the production relay, and the blocker is
no longer credentials — it is that neither app can be installed, and
that a node never recovers from a dropped connection.**

M1 (protocol + relay-core) is fully built and tested.
`packages/adapter-android` is a substantially complete node — Bluetooth
Classic connect/disconnect, the node interface over real MQTT,
call/VoIP/media trigger detection (#165/#168 added media, hardened for
real devices by #174/#175/#176), a foreground `Service` composition
root, a provisioning UI with a bonded-device picker, and heartbeats
(#142). Several on-device-only failures have been found and fixed since
the last snapshot: an MQTT connect that hung forever on the phone while
working from the JVM (#158), an uncaught Bluetooth error taking down the
whole adapter (#161), and an RFCOMM socket that could not move the audio
route (#162, the Android mirror of the Mac's own #95→#101 correction).
`packages/adapter-mac` has now caught up: real classic-Bluetooth
connect/disconnect via `IOBluetooth` (#95, corrected by #101), the node
interface over real MQTT (#112), VoIP trigger detection (#127), a
menu-bar composition root (#128), a provisioning UI with a paired-device
picker (#143), media-playback detection via CoreAudio (#166/#169), and
heartbeats (#142). Both adapters also suppress their own side effects for
~3s after acting, so thrw stops misreading its own claim/release as a
fresh trigger (#167/#170, ADR 0010). `packages/adapter-linux` has a
bootstrapped BlueZ connection seam (#108), one stage behind where
adapter-mac was before #112. `packages/adapter-ipad` is still a bare
skeleton and, per #115's research, faces a real platform ceiling (below).

`services/relay-hosted` is done for this stage: a live EMQX broker on GCP
(#80/#81), TLS termination (#119), and #118's real
`PriorityEngine`/`DeviceRegistry` process actually deployed alongside it
and verified end-to-end against `relay.thrw.app` (#129). Every other
service (`licensing`, `billing`, `accounts`, `ai-engine`, `telemetry`)
remains a one-line placeholder, genuinely not started.

The relay has also learned to recover its own state: it re-claims for a
node that restarts while holding the resource (#173/#177), and every
node re-announces itself every 2 minutes carrying its currently-active
triggers, so a relay that lost its in-memory picture — on restart, or
merely on its MQTT connection dropping — gets it back without anyone
restarting an adapter by hand (#178/#185).

**#147 is closed: both adapters can now authenticate against the
production broker**, reading `relay.username`/`relay.password` from a
gitignored `config/adapter.local.properties` overlay (ADR 0005). What
blocks a real demo now is three separate things, none of them adapter
logic:

1. ~~A node never recovers from a dropped connection (#182)~~ — **fixed
   and verified on real hardware the same day** (#192): both platforms
   reconnect after connectivity loss, and a claim was confirmed
   delivered on a restored subscription, which is the part that matters
   — a client that returns but is deaf looks identical to a healthy one
   until a claim goes missing (#197).
2. **Neither app can be installed.** CI builds an Android AAB, which
   cannot be sideloaded (#188), and no Mac `.app` artifact exists at
   all (#189) — while any CI-built release would ship with empty relay
   credentials anyway (#187). See M10.
3. **The ADR 0015 topic migration hasn't happened** (#171), and should
   land before test builds are installed so the apps are installed once
   against the real topic structure, carrying ADR 0018's command
   sequence numbers as the same flag day.

Everything adapter-side in M3 is still verified only against fakes, a
local broker, or ad-hoc manual runs. Bluetooth has never run in CI at
all — there is no hardware — so both gateways' real connect/disconnect
paths are exercised only when Tom runs them.

### Reliability hardening, decided but not yet built

ADRs 0018-0020 (#184) closed five failure classes on paper — state
reconciliation and command idempotency, confirmed switch outcomes with
failure telemetry, and relay-side debouncing with defined offline
behaviour — and #186 corrected three of those decisions from
measurements on the reference hardware before any of it was
implemented. Two consequences for this roadmap:

- **AGENTS.md now sequences this work ahead of peripheral (HID) adapter
  work and further focus-tracking**, which bears on M4's and M9's
  ordering below.
- Of it, only the periodic-reconciliation carrier exists (#185). The
  audio-route reporting it is supposed to carry (#191), confirmed
  outcomes (ADR 0019) and coalescing/offline behaviour (ADR 0020) are
  unbuilt, and only #191 has an issue so far.

`docs/testing/compatibility-matrix.md` (#184) is where verified
hardware combinations are recorded, and #197 filled in its first row
from a real pass against `relay.thrw.app`: a media-driven switch in
both directions with route evidence on each side, no oscillation when
the losing device kept playing (the first real exercise of #167's
self-cooldown in a handoff), and reconnect verified on both platforms.

Explicitly **not** verified by that pass, and still open in #193: the
call trigger and auto-return, manual claim, out-of-range behaviour,
clean-install provisioning, any other headset, and any non-Pixel
Android. The file's own rule is that an untested combination stays
unverified however similar it looks, so that list is not a formality.

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

The previous version of this section was entirely about #147, which is
closed. Before that it was about #127/#128, also closed. That is the
third time, hence the reading rule at the top of this file: check the
issue numbers below before trusting the prose around them.

**The goal this sequence serves: test builds of both apps, installed on
the reference hardware, used daily for a few days.** Everything below is
ordered by what that requires, and #193 is the pass that ends it.

1. ~~#182 — adapters must survive a dropped connection.~~ **Done**
   (#192), and verified on hardware rather than only in tests: both
   platforms reconnect, and a claim arrived on a restored subscription
   (#197). This was the item everything else waited on.
2. **#171 — the ADR 0015 topic migration, carrying ADR 0018's command
   sequence numbers and relay epoch as one flag day.** Both change the
   same command payloads across `packages/protocol`, `packages/relay-core`,
   `services/relay-hosted` and both adapters, and each alone already
   costs a relay redeploy and a reinstall on both devices. Doing them
   together means the structure under test is the real one and the apps
   are installed once. If ever split, 0015 goes first — its topic shape
   is what the sequence number rides on.
3. **#187, #188, #189 — an artifact that installs and can authenticate**,
   with #190 as the cleanup each of them will otherwise trip over. See
   M10a.
4. **#191 — reconcile the audio route, not the Bluetooth link.** Worth
   landing before the QA pass rather than after: on multipoint headsets
   both devices report a live Bluetooth link at once, so under the link
   reading both adapters claim to hold the headset and the relay cannot
   resolve the drift. That makes a hardware session confusing rather
   than informative — and confusion is expensive when the whole point
   is to learn what real devices do.
5. **#193 — the QA pass**, now worth narrowing rather than re-running:
   #197 already evidenced the media-driven switch both ways, the
   self-cooldown holding, and reconnect. What remains unverified is the
   call trigger and auto-return, manual claim, out-of-range, and
   clean-install provisioning — plus everything on non-reference
   hardware, which the matrix treats as unverified on principle.

Worth being plain about how thin the evidence still is. One pass on one
headset and two hosts, much of it observed rather than instrumented,
against adapters whose Bluetooth paths have never run in CI — there is
no hardware — so `IOBluetoothPeripheralGateway`'s and
`AndroidBluetoothClassicGateway`'s real connect/disconnect paths are
exercised only when someone runs them by hand. Days of ordinary use are
a different test from one deliberate session, which is the point of
getting installable builds onto the devices.

Not on the critical path, but cheap and due: #180 (`deploy.yml` breaks
permanently after any manual deploy) will bite during a testing week,
since it involves redeploying the relay. #183 (a spurious `call` event,
seen once) is unexplained and will muddy the signal if it recurs.

Lower-priority, but each unblocked and ready to scope whenever it's
prioritized: `packages/adapter-linux`'s node-interface/MQTT wiring
(mirroring #112's own shape, one milestone behind where Mac just got to),
and `packages/adapter-ipad`'s now-scoped bootstrap (#115 answered the
open question — an issue can be written today around "observe + prompt,"
not "connect/disconnect").

**Accepted but untracked**, and the most likely thing to quietly rot:
ADR 0019's confirmed switch outcomes and ADR 0020's relay-side
coalescing, fail-safe offline behaviour and reconnect jitter have no
issues open against them. Both are accepted policy in `docs/adr/`, both
are deliberately sequenced after the first hardware pass, and neither
will happen on its own. #191 is the only one of the three reliability
ADRs' implementation work currently tracked.
