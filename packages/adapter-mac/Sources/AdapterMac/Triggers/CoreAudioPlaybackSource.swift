#if canImport(CoreAudio)

import CoreAudio
import Foundation

/// Real ``AudioPlaybackSource``, backed by CoreAudio's
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default output
/// device.
///
/// Public API throughout - deliberately not the private
/// `MediaRemote.framework`. See ``MediaTriggerMonitor``'s kdoc for that
/// trade-off.
///
/// ## Why it also watches the *default device*, not just one device
///
/// The device this listens to is not stable: plugging in headphones,
/// AirPods connecting, or a display's speakers appearing all change the
/// default output. A listener bound to the old device is silently dead -
/// it reports nothing and looks exactly like "no audio playing".
///
/// That matters especially here, because **thrw's own claim changes the
/// output device**: connecting the headset makes it the default, which
/// would orphan a listener attached to the previous one. So this watches
/// `kAudioHardwarePropertyDefaultOutputDevice` too, and re-attaches.
///
/// Not exercised by this package's tests - CI has no audio device, and
/// the property callbacks need a real CoreAudio stack.
/// ``MediaTriggerMonitor`` holds the logic and is tested against a fake.
public final class CoreAudioPlaybackSource: AudioPlaybackSource, @unchecked Sendable {
    public init() {}

    public func events() -> AsyncStream<AudioPlaybackEvent> {
        AsyncStream { continuation in
            let state = ListenerState(continuation: continuation)
            state.start()
            continuation.onTermination = { _ in state.stop() }
        }
    }

    /// Holds the CoreAudio listener registrations so they can be removed
    /// on termination - a leaked property listener fires against a freed
    /// continuation.
    private final class ListenerState: @unchecked Sendable {
        private let continuation: AsyncStream<AudioPlaybackEvent>.Continuation
        private let lock = NSLock()
        private var watchedDevice: AudioDeviceID?
        private var lastReported: Bool?

        init(continuation: AsyncStream<AudioPlaybackEvent>.Continuation) {
            self.continuation = continuation
        }

        private lazy var deviceChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebindToDefaultDevice()
        }

        private lazy var runningChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.publishCurrentState()
        }

        func start() {
            var addr = Self.defaultOutputDeviceAddress
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, nil, deviceChanged
            )
            rebindToDefaultDevice()
        }

        func stop() {
            var addr = Self.defaultOutputDeviceAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, nil, deviceChanged
            )
            lock.lock()
            if let device = watchedDevice {
                var running = Self.isRunningAddress
                AudioObjectRemovePropertyListenerBlock(device, &running, nil, runningChanged)
                watchedDevice = nil
            }
            lock.unlock()
            continuation.finish()
        }

        private func rebindToDefaultDevice() {
            lock.lock()
            if let previous = watchedDevice {
                var running = Self.isRunningAddress
                AudioObjectRemovePropertyListenerBlock(previous, &running, nil, runningChanged)
            }
            let device = Self.defaultOutputDevice()
            watchedDevice = device
            if let device {
                var running = Self.isRunningAddress
                AudioObjectAddPropertyListenerBlock(device, &running, nil, runningChanged)
            }
            lock.unlock()
            publishCurrentState()
        }

        /// Only emits on a *change*, so re-binding to a device that is in
        /// the same state doesn't restart the monitor's debounce.
        private func publishCurrentState() {
            lock.lock()
            let device = watchedDevice
            let running = device.map(Self.isRunning) ?? false
            let changed = lastReported != running
            lastReported = running
            lock.unlock()
            guard changed else { return }
            continuation.yield(running ? .started : .stopped)
        }

        private static var defaultOutputDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        private static var isRunningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        private static func defaultOutputDevice() -> AudioDeviceID? {
            var addr = defaultOutputDeviceAddress
            var device = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device
            )
            return status == noErr && device != 0 ? device : nil
        }

        private static func isRunning(_ device: AudioDeviceID) -> Bool {
            var addr = isRunningAddress
            var running = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running)
            return status == noErr && running != 0
        }
    }
}

#endif
