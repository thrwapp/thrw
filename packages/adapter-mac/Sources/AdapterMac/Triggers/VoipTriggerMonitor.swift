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
/// A VoIP session is **a known VoIP app running AND the microphone
/// live** (#247). The bundle identifier must be in
/// ``VoipTriggerMonitor/defaultVoipBundleIdentifiers`` (or whatever set
/// the caller supplies), and ``MicrophoneActivitySource`` must report
/// the mic open.
///
/// ## Correction: the microphone *is* observable
///
/// This kdoc used to say macOS has no public API for "is this app
/// currently in a call" and that "not even 'is the microphone in use by
/// another app' is exposed to third parties (confirmed while researching
/// #127)". **The second half was wrong**, and it shaped the design for
/// several issues before anyone retested it.
///
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input
/// device reports exactly that. It is public CoreAudio, needs no TCC
/// grant, and covers other processes rather than only our own - verified
/// on the reference Mac reading `false` idle and `true` with a call
/// live, from an untrusted process. What #127 actually tested is
/// unknown; possibly a different API.
///
/// The first half stands: there is still no "is *this app* in a call"
/// signal, so this remains an inference from two coarse facts rather
/// than a direct reading. It is a much better inference than app-running
/// alone, which is all it used to be.
///
/// Still cruder than `adapter-android`'s, which is backed by
/// notification properties that name an ongoing call directly
/// (`FLAG_ONGOING_EVENT`, `CATEGORY_CALL`, `CallStyle`'s
/// `CALL_TYPE_ONGOING`).
///
/// ## Known limitations
///
/// - **A muted call still counts**, because most apps keep the mic
///   stream open when muted. That is the right answer - you are in a
///   call - but worth knowing it is not "is the user speaking".
/// - **A listen-only call does not count**: joining a webinar and never
///   unmuting leaves the mic closed. `media` covers the audio in that
///   case, one rank lower.
/// - **The mic could be live for something else entirely** - Voice
///   Memos, a screen recording. A false positive now needs a known VoIP
///   app open *and* the mic live simultaneously, which is much rarer
///   than either alone but not impossible.
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
    private let microphone: MicrophoneActivitySource?
    private let node: EventLifecycle
    private let voipBundleIdentifiers: Set<String>
    private var activeBundleIdentifiers: Set<String> = []
    /// #247 - whether anything on this Mac currently has the mic open.
    /// Starts `false`: with no microphone source supplied this stays
    /// false forever, which is why `emitted` ignores it in that case.
    private var microphoneInUse = false
    /// Whether `voip` is currently reported to the relay. Tracked
    /// explicitly because the trigger is now a function of *two* inputs,
    /// and either can change independently - deriving "should we emit"
    /// from one of them alone is what made the old version wrong.
    private var emitted = false

    public init(
        source: RunningApplicationSource,
        node: EventLifecycle,
        microphone: MicrophoneActivitySource? = nil,
        voipBundleIdentifiers: Set<String> = VoipTriggerMonitor.defaultVoipBundleIdentifiers
    ) {
        self.source = source
        self.microphone = microphone
        self.node = node
        self.voipBundleIdentifiers = voipBundleIdentifiers
    }

    /// Whether a `voip` trigger should currently be reported (#247).
    ///
    /// **A known VoIP app running AND the microphone live.** The app
    /// being open is not a call: leaving Slack or WhatsApp open all day
    /// used to pin the headset to this Mac indefinitely, because `voip`
    /// outranks `media` in `PRIORITY_ORDER` and nothing ever ended it.
    ///
    /// Without a ``MicrophoneActivitySource`` this degrades to the old
    /// app-running-only behaviour rather than never firing - a monitor
    /// built without one should keep working as it always did, and
    /// silently never reporting VoIP would be a worse failure than
    /// over-reporting it.
    private var shouldEmit: Bool {
        guard !activeBundleIdentifiers.isEmpty else { return false }
        return microphone == nil ? true : microphoneInUse
    }

    /// Emits or ends `voip` if the two inputs now disagree with what the
    /// relay has been told. The single place that talks to the node, so
    /// the start/end pairing cannot get out of step.
    private func reconcile() async throws {
        let wanted = shouldEmit
        guard wanted != emitted else { return }
        emitted = wanted
        if wanted {
            try await node.emitEvent(type: .voip, priority: unrankedPriority)
        } else {
            try await node.endEvent(type: .voip)
        }
    }

    /// Collects running-application events and reports trigger start/
    /// end. Suspends until the source's stream completes or the calling
    /// task is cancelled.
    /// Collects both inputs and reports trigger start/end.
    ///
    /// The two streams are consumed by separate child tasks because
    /// either can change independently - an app launching while the mic
    /// is already live, or a call starting in an app that has been open
    /// for hours. Serialised onto this monitor's own isolation so
    /// `reconcile` is never re-entered concurrently.
    public func run() async throws {
        guard let microphone else {
            for await event in source.events() {
                try await handle(event)
            }
            return
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            let source = self.source
            group.addTask { [weak self] in
                for await event in source.events() {
                    try await self?.handle(event)
                }
            }
            group.addTask { [weak self] in
                for await inUse in microphone.activity() {
                    try await self?.handleMicrophone(inUse)
                }
            }
            // Either stream ending ends the monitor, matching the
            // single-source behaviour above. `next()` rethrows, so a
            // failure in one child is not swallowed by the other.
            try await group.next()
            group.cancelAll()
        }
    }

    /// Handles one running-application event. Exposed separately from
    /// `run` so a test can drive it directly.
    func handle(_ event: RunningApplicationEvent) async throws {
        switch event {
        case .launched(let app):
            guard voipBundleIdentifiers.contains(app.bundleIdentifier) else { return }
            activeBundleIdentifiers.insert(app.bundleIdentifier)
        case .terminated(let app):
            activeBundleIdentifiers.remove(app.bundleIdentifier)
        }
        try await reconcile()
    }

    /// Handles one microphone-activity change (#247). Exposed for tests
    /// for the same reason as ``handle(_:)``.
    func handleMicrophone(_ inUse: Bool) async throws {
        microphoneInUse = inUse
        try await reconcile()
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
