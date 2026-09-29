# Testing framework: a deterministic scenario simulator

Status: **proposed, 2026-09-29.** This is the design for Phase 1 of the v1
plan (`docs/roadmap.md`). It is judged against `docs/spec/scenarios.md`:
the framework is done when every scenario in that file is executable in
it.

## Why this exists

Every bug of the last week was found by Tom holding two devices, fixed
by an agent against mocks, and shipped. The mocks were faithful to the
APIs they replaced and blind to how the hardware behaves over time: that
a connect is accepted long before it completes (#257), that changing the
default output device blips the "is audio playing" signal (#298), that
thrw's own pause looks like the user stopping their music (#295), that a
connect can simply never return (#303). Every one of those is a
*property of the world*, not of any one component, and no unit test was
looking at the world.

The simulator puts the world in a test. It also makes agent-driven
development observable: an agent that can run the scenarios can see
what it is changing, without Tom or the hardware.

## Shape

    scenario (JSON)          world model               relay (real code)
    ─────────────────        ─────────────────         ─────────────────
    initial state      ──▶   physical events    ──▶    RelayService
    timeline of            → per-node signals          PriorityEngine
      physical events        (with thrw's own          CommandCoalescer
    expectations             side effects)                 ▲    │
                                    │                      │    │
                                    ▼                      │    ▼
                              node models  ◀── in-memory bus (no broker)
                              (Mac, Pixel)
                                    │
                         all on one virtual clock

Everything runs on one virtual clock over an in-memory bus. A 14-day
run takes seconds, and the same seed gives the same run every time.

### 1. Scenario files

One JSON file per scenario, named by its ID, in
`packages/testkit/scenarios/`. Language-neutral on purpose: the Swift
and Kotlin suites read the same files (see *Conformance*).

```json
{
  "id": "N5",
  "title": "Media on both devices: no bouncing",
  "initial": { "holder": "mac", "headset": "worn" },
  "timeline": [
    { "at": "0s",  "node": "mac",   "event": "media_start", "app": "youtube" },
    { "at": "10s", "node": "pixel", "event": "media_start", "app": "spotify" }
  ],
  "expect": [
    { "during": ["20s", "300s"], "holderChangesAtMost": 0 },
    { "at": "300s", "routeEqualsHolder": true }
  ],
  "runFor": "300s"
}
```

`event`s are what a person or the world does (press play, a call rings,
headset into the case, the Mac sleeps), never what an adapter reports.
Translating one into the other is the world model's job, and getting
that translation wrong is exactly the class of bug this exists to catch.

### 2. The world model

The most valuable part, because it encodes what the hardware actually
does. Every number is a parameter with a cited source, so a new
hardware capture tightens it by changing one value.

| Behaviour | Default | Source |
|---|---|---|
| Mac release (disconnect to route gone) | ~2.2s | #254 |
| Pixel claim (request to route observed) | ~3.3-4.9s | #254, #310 |
| Pixel connect accepted, not yet connected | ~18ms accepted, seconds to connect | #257 |
| Multipoint: both hosts hold a link, one holds the route | on | ADR 0018, #186 |
| Default-output change blips `DeviceIsRunningSomewhere` | ~0.5s false | #298 |
| thrw's handover pause reads as media stopped | on | #295 |
| Spotify leaves `STATE_PLAYING` (buffering) | ~1-2s every ~4min | #288 |
| IOBluetooth connect never resumes | off, injectable | #303 |
| Headset in case: connect refused | ~3s to unreachable | #264 |
| Mac asleep / Pixel dozing: no heartbeats | per scenario | #263 |

Faults are injectable per scenario (`"faults": ["connect_hangs"]`), so
must-recover scenarios can ask for the world to misbehave.

### 3. Node models

TypeScript models of each adapter's decision logic: triggers, start and
stop debounce, the self-cooldown, the audio gate, route reporting,
registration, command handling and outcome reporting. One for the Mac,
one for the Pixel, because they genuinely differ (the Mac cannot see
phone calls; the debounce and pause mechanisms differ).

The relay is **not** modelled. `RelayService` runs unmodified.

### 4. Conformance: keeping the models honest

A model that drifts from the real adapter is worse than no model. So
every simulator run records, per node, a trace of inputs (signals
received, commands received) and outputs (events and outcomes
published), and those traces are fixtures that the real `MacNode`
(`swift test`) and `AndroidNode` (`./gradlew test`) replay. If the real
adapter's output differs from the model's, the test fails, and the
scenario set becomes a regression suite for the native code too.

Prerequisite: both adapters take an injectable clock. Today they read
`ContinuousClock.now` and sleep for real, which is also why the Mac's
runtime tests needed a 10s deadline to stop flaking in CI (#298).

### 5. Invariants and fuzzing

Hand-written scenarios only find the bugs someone thought of. The
fuzzer generates random timelines of physical events and checks
properties that must hold whatever happened:

- **Settles correctly.** Once no event has happened for a quiet period,
  the route equals what arbitration says it should be. (No stuck
  states; #303 and #307 both violate this.)
- **Never interrupts a call.** While a call is live on a device, the
  route never leaves it.
- **No bouncing.** At most N holder changes in any 60s window.
- **Every command resolves.** Every claim and release reaches an ADR
  0019 outcome within the bound.

A failure is shrunk to the shortest timeline that still fails and
written out as a new scenario file. That is the loop an agent can run
without anyone holding a phone.

### 6. Capture import

A parser turns `scripts/qa-capture.sh` output into a scenario timeline,
so a bug seen in daily use becomes a failing test without retyping.
#303 and #307 are the first two to import.

## Build order

Each step is one agent-sized issue and lands green on its own.

1. **Virtual clock and in-memory bus.** No behaviour change.
   - Extract a `RelayTransport` interface from the four
     `RelayMqttClient` methods `RelayService` calls:
     `subscribeAllEvents`, `subscribeHeartbeat`, `publishCommand`,
     `publishState`. `RelayService` depends on the interface;
     `RelayMqttClient` implements it.
   - **Watch:** `publishCommand` stamps ADR 0018's epoch and sequence
     number inside the client. Either move stamping into `RelayService`
     or have the in-memory transport stamp identically; the first is
     cleaner and must keep `packages/relay-core`'s existing tests green.
   - `packages/testkit`: `VirtualClock` (implements relay-core's
     `Scheduler` plus a `now()`, advances only when told) and
     `InMemoryBus` (implements `RelayTransport`, delivers in a defined
     order on the virtual clock).
   - Port `handoff-integration.test.ts` onto it as the proof, keeping
     one real-broker test per path so the MQTT wiring itself stays
     covered.
2. **Scenario runner, world model, node models.** First scenarios: M1,
   M5, N5, plus regressions for #303 and #307. Some will fail on v0.2.5;
   they are marked expected-fail with the scenario ID, never skipped.
3. **Conformance.** Injectable clocks in both adapters, trace export,
   replay tests for the first scenarios. The Swift half runs on the
   MacBook Air CI runner.
4. **The rest of the scenario set, then the fuzzer and invariants.**
5. **Capture import.**
6. **Latency reporting.** The simulator reports switch-time
   distributions, so Phase 3's changes (claim on ring, profile order)
   are evaluated before they reach hardware.

## Open decision: where the heuristics live

The node models exist only because trigger interpretation and
debouncing live in the adapters. If Phase 2's arbitration ADR moves
that interpretation to the relay, adapters report raw observations and
execute commands, and then nearly all decision logic is TypeScript that
runs in the simulator directly, conformance only has to check that
adapters report faithfully, and the models become trivial.

That is a frozen-contract change, so it is an ADR and Tom's call. The
simulator is worth building first either way: it is the evidence for or
against moving the logic.

## Out of scope

- **Automated hardware in the loop.** Media can be driven over `adb` and
  `osascript`, but not a real call and not the headset going into its
  case. Hardware stays the scripted manual pass that confirms, per
  `scenarios.md`.
- **A real broker in the main loop.** One real-broker test per path,
  nothing more.
