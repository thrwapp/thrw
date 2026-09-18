import Foundation

/// Turns running-app state (via ``RunningApplicationSource``) into the
/// node's `voip` trigger - architecture.md's rule 3, "VoIP session
/// started on any node - Zoom/Meet/Teams/WhatsApp".
///
/// ## Why this is the *only* trigger this package can detect
///
/// architecture.md's "System components" section named `AVAudioSession +
/// process watching` as Mac's trigger APIs - **`AVAudioSession` doesn't
/// exist on macOS.** It's an iOS/tvOS/watchOS-only framework (confirmed
/// against Apple's own documentation and forums while researching #127 -
/// see `docs/spec/architecture.md`'s corrected line and #127's handoff
/// for citations). macOS's real audio-route API is Core Audio
/// (`kAudioHardwarePropertyDefaultOutputDevice`), but it only reports
/// *what* the current output device is, not *why* it changed - there's
/// no "a call started" semantic to key off the way iOS's route-change-
/// reason enum has, so it isn't used here as a trigger signal at all.
///
/// Rule 1 ("incoming/outgoing phone call - always wins") has **no
/// implementation on Mac and isn't expected to get one soon**: Macs
/// don't take cellular calls, and there is no public API for a
/// third-party app to observe FaceTime's or any other app's call state.
/// (CallKit has only just begun shipping on macOS, in beta, as of very
/// recent Xcode 26.x releases - a single incremental `CXProvider` method
/// as of this research, nowhere near a documented, stable surface worth
/// building a production feature on.) This is a real, permanent-for-now
/// product gap, not a temporary implementation shortfall - the Mac
/// adapter reports VoIP sessions; it cannot report phone calls.
///
/// ## The heuristic
///
/// A running app counts as an active VoIP session when its bundle
/// identifier is in ``VoipTriggerMonitor/defaultVoipBundleIdentifiers``
/// (or whatever set the caller supplies instead). This is deliberately
/// cruder than `adapter-android`'s own `VoipTriggerMonitor` heuristic:
/// Android's is backed by *notification properties* that distinguish an
/// actually-ongoing call from an app merely being open (`FLAG_ONGOING_EVENT`,
/// `CATEGORY_CALL`, `CallStyle`'s `CALL_TYPE_ONGOING`). macOS has no
/// public API for "is this app currently in a call" at all - not even
/// "is the microphone in use by another app" is exposed to third parties
/// (confirmed while researching #127). So this can only observe "is a
/// known VoIP app *running*", which is a strictly weaker, higher-false-
/// positive signal (the app being open doesn't mean a call is active)
/// documented here rather than silently assumed equivalent to Android's.
///
/// ## Known limitations
///
/// - **False positives**: a VoIP app sitting open with no active call
///   still counts as "in a VoIP session" - there is no way to distinguish
///   "open" from "actively calling" with public APIs.
/// - **Browser-based VoIP is invisible**: Google Meet (no native Mac app)
///   and any VoIP session running inside a browser tab can't be detected
///   this way - process watching only sees the browser process, which
///   carries no signal about what's happening inside a specific tab.
/// - **`defaultVoipBundleIdentifiers` is a starting set, not verified
///   against real installs** - bundle identifiers for apps like Microsoft
///   Teams have changed across major rewrites before and could again;
///   this set is constructor-injectable specifically so a wrong/missing
///   identifier is a configuration fix, not a code change (same pattern
///   `adapter-android`'s own `telephonyPackages` constructor parameter
///   uses).
///
/// No state machine here, and no priority decision: this reports what it
/// sees, the relay decides (architecture.md) - same discipline
/// `adapter-android`'s own `VoipTriggerMonitor` follows.
public final class VoipTriggerMonitor {
    private let source: RunningApplicationSource
    private let node: EventLifecycle
    private let voipBundleIdentifiers: Set<String>
    private var activeBundleIdentifiers: Set<String> = []

    public init(
        source: RunningApplicationSource,
        node: EventLifecycle,
        voipBundleIdentifiers: Set<String> = VoipTriggerMonitor.defaultVoipBundleIdentifiers
    ) {
        self.source = source
        self.node = node
        self.voipBundleIdentifiers = voipBundleIdentifiers
    }

    /// Collects running-application events and reports trigger start/
    /// end. Suspends until the source's stream completes or the calling
    /// task is cancelled.
    public func run() async throws {
        for await event in source.events() {
            try await handle(event)
        }
    }

    /// Handles one running-application event. Exposed separately from
    /// `run` so a test can drive it directly.
    func handle(_ event: RunningApplicationEvent) async throws {
        switch event {
        case .launched(let app):
            try await startSession(app.bundleIdentifier)
        case .terminated(let app):
            try await endSession(app.bundleIdentifier)
        }
    }

    private func startSession(_ bundleIdentifier: String) async throws {
        guard voipBundleIdentifiers.contains(bundleIdentifier) else { return }
        let wasEmpty = activeBundleIdentifiers.isEmpty
        guard activeBundleIdentifiers.insert(bundleIdentifier).inserted else { return }
        if wasEmpty {
            try await node.emitEvent(type: .voip, priority: unrankedPriority)
        }
    }

    private func endSession(_ bundleIdentifier: String) async throws {
        guard activeBundleIdentifiers.remove(bundleIdentifier) != nil else { return }
        if activeBundleIdentifiers.isEmpty {
            try await node.endEvent(type: .voip)
        }
    }

    /// Bundle identifiers of common VoIP/conferencing apps with a native
    /// Mac app - see this type's "Known limitations" for what this
    /// deliberately can't cover (browser-based VoIP), and its own kdoc
    /// for why this is a starting set rather than a verified one.
    public static let defaultVoipBundleIdentifiers: Set<String> = [
        "com.apple.FaceTime",
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "net.whatsapp.WhatsApp",
        "com.skype.skype",
    ]
}
