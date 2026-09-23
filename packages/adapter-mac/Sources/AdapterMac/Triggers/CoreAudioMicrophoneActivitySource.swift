import CoreAudio
import Foundation

/// Real ``MicrophoneActivitySource``, backed by CoreAudio (#247).
///
/// Reads `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default
/// input device - "some process on this machine has this device live".
/// Public API, no TCC grant, and it reports other applications' use, not
/// just our own.
///
/// Not unit-tested, for the same reason ``NSWorkspaceRunningApplicationSource``
/// and ``CoreAudioRouteObserver`` are not: this package's tests run
/// without audio hardware or other processes to observe.
/// ``VoipTriggerMonitor`` holds the logic and is tested against a fake of
/// the protocol above.
///
/// ## Why it listens on two properties
///
/// The obvious listener - is-running-somewhere on the current default
/// input - misses the case where the *default input device itself*
/// changes, which happens when a headset with a microphone connects or
/// disconnects. That is not a corner case here: thrw moves headsets for
/// a living, so the default input changing mid-session is routine. So
/// the default-device property is watched too, and the per-device
/// listener is re-pointed when it moves.
public final class CoreAudioMicrophoneActivitySource: MicrophoneActivitySource, @unchecked Sendable {
    public init() {}

    public func activity() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let state = ListenerState(continuation: continuation)
            state.start()
            continuation.onTermination = { _ in state.stop() }
        }
    }

    /// Holds the CoreAudio listener blocks so they can be removed again.
    ///
    /// A class rather than locals because `AudioObjectRemovePropertyListenerBlock`
    /// needs the *same block reference* that was added - capturing them
    /// is the only way to unregister, and a leaked listener keeps firing
    /// into a finished stream.
    private final class ListenerState: @unchecked Sendable {
        private let continuation: AsyncStream<Bool>.Continuation
        private let queue = DispatchQueue(label: "app.thrw.mac.micActivity")
        private var watchedDevice: AudioDeviceID?
        private var deviceListener: AudioObjectPropertyListenerBlock?
        private var defaultListener: AudioObjectPropertyListenerBlock?
        private var lastReported: Bool?

        init(continuation: AsyncStream<Bool>.Continuation) {
            self.continuation = continuation
        }

        func start() {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.repoint()
            }
            defaultListener = listener
            var address = Self.defaultInputAddress
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, listener
            )
            repoint()
        }

        func stop() {
            queue.sync {
                if let block = defaultListener {
                    var address = Self.defaultInputAddress
                    AudioObjectRemovePropertyListenerBlock(
                        AudioObjectID(kAudioObjectSystemObject), &address, queue, block
                    )
                    defaultListener = nil
                }
                removeDeviceListener()
            }
        }

        /// Points the per-device listener at whatever the default input
        /// is now, and reports the current value.
        private func repoint() {
            queue.async { [weak self] in
                guard let self else { return }
                let device = Self.defaultInputDevice()
                if device != self.watchedDevice {
                    self.removeDeviceListener()
                    if let device {
                        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                            self?.report()
                        }
                        self.deviceListener = block
                        var address = Self.isRunningAddress
                        AudioObjectAddPropertyListenerBlock(device, &address, self.queue, block)
                    }
                    self.watchedDevice = device
                }
                self.report()
            }
        }

        private func removeDeviceListener() {
            guard let device = watchedDevice, let block = deviceListener else { return }
            var address = Self.isRunningAddress
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
            deviceListener = nil
        }

        /// Emits only on a *change*. CoreAudio fires a listener for
        /// several reasons, and re-emitting an unchanged value would make
        /// the monitor re-evaluate - and potentially re-emit a trigger -
        /// for nothing.
        private func report() {
            let inUse = watchedDevice.flatMap(Self.isRunningSomewhere) ?? false
            guard inUse != lastReported else { return }
            lastReported = inUse
            continuation.yield(inUse)
        }

        private static var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        private static var isRunningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        private static func defaultInputDevice() -> AudioDeviceID? {
            var device = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var address = defaultInputAddress
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
            )
            return status == noErr ? device : nil
        }

        /// `nil` rather than `false` on an unreadable property, so the
        /// caller can tell "no microphone in use" from "cannot tell".
        /// ``report`` treats both as not-in-use, deliberately: a VoIP
        /// trigger that fires because we *could not determine* the mic
        /// state would be the old over-triggering bug wearing a hat.
        private static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool? {
            var running = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = isRunningAddress
            let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
            return status == noErr ? running != 0 : nil
        }
    }
}
