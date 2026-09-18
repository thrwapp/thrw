import Foundation

/// How long audio must run continuously before it counts as media (#166).
///
/// CoreAudio's `kAudioDevicePropertyDeviceIsRunningSomewhere` reports
/// that *something* is using the output device. It cannot say what. A UI
/// click, a notification chime, a Slack whoosh and an album all look
/// identical to it.
///
/// A debounce is the trade chosen here: audio must be continuous for this
/// long before the trigger fires. Two seconds comfortably outlasts every
/// system sound (which are well under a second) while still feeling
/// immediate when you actually press play. The cost is stated plainly:
/// **the Mac takes ~2s longer than Android to claim for media**, because
/// Android can read a real playback state and this cannot.
///
/// The alternative - fire immediately and let the relay's priority rules
/// sort it out - was rejected: a notification sound would yank the
/// headset off another device, which is exactly the behaviour that makes
/// this kind of tool feel hostile.
public let defaultMediaDebounce: Duration = .seconds(2)

/// Turns "this Mac is playing audio" into the node's `media` trigger -
/// architecture.md's rule 4.
///
/// ## Weaker than Android's, deliberately and unavoidably
///
/// `adapter-android`'s equivalent reads `MediaSessionManager`, which
/// reports real per-app playback state (`STATE_PLAYING` for a named
/// package). macOS exposes no public equivalent: the only supported
/// signal is "is the output device in use", from CoreAudio.
///
/// The private `MediaRemote.framework` (`MRMediaRemoteGetNowPlayingInfo`)
/// would give richer now-playing data, and is deliberately **not** used -
/// Apple has progressively restricted it, and a private framework is a
/// worse dependency than the debounce heuristic below. See #166.
///
/// Known limitations, in the same spirit as ``VoipTriggerMonitor``'s:
/// - **It cannot name the app.** "Media is playing" is all this knows.
/// - **A long notification sound could still trip it**, if one ran past
///   the debounce window. None of the system sounds do.
/// - **It reports this Mac's output device**, so audio playing to some
///   other device on this machine still counts as media here.
public final class MediaTriggerMonitor {
    private let source: AudioPlaybackSource
    private let node: EventLifecycle
    private let debounce: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    /// True once the debounce has elapsed and `media` has been reported.
    private var reportedMedia = false
    /// The in-flight debounce, cancelled if audio stops before it fires.
    private var pending: Task<Void, Never>?

    public init(
        source: AudioPlaybackSource,
        node: EventLifecycle,
        debounce: Duration = defaultMediaDebounce,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.source = source
        self.node = node
        self.debounce = debounce
        self.sleep = sleep
    }

    /// Collects playback events and reports trigger start/end. Suspends
    /// until the source's stream completes or the calling task is
    /// cancelled.
    public func run() async throws {
        for await event in source.events() {
            try await handle(event)
        }
        pending?.cancel()
    }

    /// Handles one playback event. Exposed separately from ``run()`` so a
    /// test can drive it directly.
    func handle(_ event: AudioPlaybackEvent) async throws {
        switch event {
        case .started:
            try await audioStarted()
        case .stopped:
            try await audioStopped()
        }
    }

    private func audioStarted() async throws {
        // Already counting, or already counted - a repeated `started`
        // must not restart the clock or double-report.
        guard pending == nil, !reportedMedia else { return }
        pending = Task { [weak self] in
            guard let self else { return }
            try? await self.sleep(self.debounce)
            guard !Task.isCancelled else { return }
            await self.debounceElapsed()
        }
    }

    private func audioStopped() async throws {
        pending?.cancel()
        pending = nil
        guard reportedMedia else { return }
        reportedMedia = false
        try await node.endEvent(type: .media)
    }

    private func debounceElapsed() async {
        pending = nil
        guard !reportedMedia else { return }
        reportedMedia = true
        try? await node.emitEvent(type: .media, priority: unrankedPriority)
    }
}
