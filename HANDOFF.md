# HANDOFF: Bluetooth connection management for packages/adapter-android (#66)

## What was done

Added Bluetooth Classic connect/disconnect state management to
`@thrw/adapter-android`, scoped strictly to local device control (no
MQTT, no `NodeInterface`, no trigger detection — those are separate
follow-up issues per the issue body):

- `packages/adapter-android/app/src/main/kotlin/com/thrw/adapter/android/bluetooth/BluetoothClassicGateway.kt` —
  a thin interface (`connect`/`disconnect`, both `suspend fun`) modeling
  the `android.bluetooth.BluetoothAdapter`/`BluetoothDevice`/`BluetoothSocket`
  connect flow, kept as its own seam so tests can fake it.
- `packages/adapter-android/app/src/main/kotlin/com/thrw/adapter/android/bluetooth/BluetoothConnectionState.kt` —
  `DISCONNECTED` / `CONNECTING` / `CONNECTED` / `DISCONNECTING` enum.
- `packages/adapter-android/app/src/main/kotlin/com/thrw/adapter/android/bluetooth/BluetoothConnectionManager.kt` —
  the class the issue asked for: `connect(deviceAddress: String)`,
  `disconnect(deviceAddress: String)`, and `connectionState(deviceAddress: String)`
  to query current state. Tracks state per device address behind a
  `Mutex`, all three are `suspend fun`.
- `packages/adapter-android/app/src/test/kotlin/com/thrw/adapter/android/bluetooth/BluetoothConnectionManagerTest.kt` —
  10 new tests against a `FakeBluetoothClassicGateway`.
- `packages/adapter-android/app/build.gradle.kts` — added
  `kotlinx-coroutines-core` (main) and `kotlinx-coroutines-test` (test).

## Acceptance criteria evidence

1. Bluetooth Classic connect/disconnect for a single paired headset,
   no root/VendorID spoofing/"act as Apple device" anywhere in the
   diff: `BluetoothConnectionManager.kt` and `BluetoothClassicGateway.kt`
   contain no such code — see "Uncertain / judgment calls" below for the
   one real caveat on this criterion (the gateway is an interface, not
   yet an `android.bluetooth`-backed implementation).
2. `BluetoothConnectionManager` class with `connect(deviceAddress: String)`,
   `disconnect(deviceAddress: String)`, and a query method:
   `BluetoothConnectionManager.kt:29`, `:54`, `:74`.
3. No relay/MQTT, no `NodeInterface`: grepped the full diff for
   `register`, `emitEvent`, `onClaim`, `onRelease`, and `mqtt` (case
   insensitive) — no matches outside this sentence in `HANDOFF.md`
   itself.
4. Tests fake the `BluetoothClassicGateway` boundary
   (`BluetoothConnectionManagerTest.kt:14-35`, `FakeBluetoothClassicGateway`)
   rather than mocking `android.bluetooth` internals, and cover: connect
   while already connected is a no-op (`:59-69`), disconnect of an
   unknown device is a no-op that never calls the gateway (`:105-114`),
   disconnect of an already-disconnected device doesn't call the gateway
   again (`:116-126`), a failed connect reverts state and rethrows
   (`:71-79`), retry after a failed connect (`:81-91`), a failed
   disconnect still leaves state `DISCONNECTED` (`:128-137`), and
   per-address independence (`:139-148`).
5. Coroutines: all three `BluetoothConnectionManager` methods are
   `suspend fun` (`BluetoothConnectionManager.kt:29,54,74`), backed by
   `kotlinx.coroutines.sync.Mutex`/`withLock` for state-transition safety
   under concurrent calls (`:19`, `:30`, `:43`, `:45`, `:55`, `:63`,
   `:69`, `:75`).
6. New dependency: `kotlinx-coroutines-core`/`kotlinx-coroutines-test`
   (`app/build.gradle.kts`). Justified — AGENTS.md's conventions section
   says "use Kotlin coroutines for async code," and that's not usable
   for real dispatch/testing without the coroutines library itself; this
   is the standard, minimal library that provides it, not an extra
   convenience dependency.

## Verification

- **I could not run `cd packages/adapter-android && ./gradlew test`
  (or `pnpm turbo test --filter=@thrw/adapter-android`) in this
  environment.** Every command that would exec a JVM (`java -version`,
  `./gradlew test`, even via `bash gradlew`/absolute path) or reach the
  network (`curl`) was blocked by this session's tool-approval policy
  with no human present to approve it, and retrying didn't change the
  outcome. This is a limitation of my execution environment, not
  something about the code. I have **not** verified the test suite
  passes — I reviewed both new files by hand for syntax/semantics
  instead (mutex-guarded state transitions, `when` exhaustiveness,
  `kotlin.test`/`kotlinx-coroutines-test` API usage matching the
  pre-existing `AdapterTest.kt`'s pattern) but that is not a substitute
  for actually running `./gradlew test`.
- The repo's own CI (`.github/workflows/ci.yml`'s `android` job)
  provisions Java 17 and runs this exact command; since AGENTS.md's
  scope section gates `packages/**` auto-merge on CI being green, that
  job running for real on this PR is the actual verification, not a
  claim I'm making here.

## Uncertain / judgment calls

- **AC1 says to use `android.bluetooth.BluetoothAdapter`/`BluetoothDevice`
  directly.** `packages/adapter-android/app/build.gradle.kts` is
  currently a plain Kotlin/JVM module, not the Android Gradle Plugin
  (its own top-of-file comment: "Placeholder... swap to
  com.android.application once [the Android SDK is] provisioned in
  CI") — so `android.bluetooth` classes aren't on this module's compile
  classpath, and code that imports them can't compile here today. AC4's
  explicit instruction to "wrap them behind your own thin interface
  first" reads like it anticipates exactly this: I implemented
  `BluetoothClassicGateway` as my own interface modeling the real
  `BluetoothAdapter`/`BluetoothDevice`/`BluetoothSocket` connect/close
  flow, and `BluetoothConnectionManager` only depends on that interface
  — but there is **no concrete `android.bluetooth`-backed implementation
  of the gateway in this PR**, because one can't compile in this module
  as currently configured. Wiring a real implementation is mechanical
  once the module moves to the Android Gradle Plugin, but that move
  itself is a build-tooling change bigger than this issue's stated scope
  ("Bluetooth connection management only") and isn't something I could
  verify compiles/tests against a real Android SDK from this
  environment either. Flagging this for human judgment rather than
  guessing whether to do the AGP swap in this PR.
- `connect()`/`disconnect()` no-op semantics (already-connected connect,
  unknown/already-disconnected disconnect) aren't specified beyond "handle
  it" in AC4 — I chose no-op-without-calling-the-gateway-again in both
  cases as the least surprising behavior; a variant that throws on these
  cases is equally defensible and wasn't ruled out by the issue text.
- A failed `disconnect()` still forces state to `DISCONNECTED`
  (`BluetoothConnectionManager.kt:66-70`) rather than leaving it in
  `DISCONNECTING` or reverting to the prior state. Reasoning: if the
  gateway's close/disconnect call throws, the safest default is not to
  keep reporting the device as connected/connecting. Not explicitly
  specified by the issue.
