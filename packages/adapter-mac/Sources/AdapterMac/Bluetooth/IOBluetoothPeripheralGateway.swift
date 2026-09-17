#if canImport(IOBluetooth)

import Foundation
import IOBluetooth
import IOKit

/// Real classic-Bluetooth ``BluetoothPeripheralGateway``, wrapping
/// `IOBluetoothDevice`'s callback API behind async/await.
///
/// Replaces #95's `CoreBluetoothPeripheralGateway` (#101). CoreBluetooth
/// on macOS is Bluetooth Low Energy only: connecting or cancelling a
/// `CBPeripheral` does not move AirPods' audio route, because that route
/// lives on the classic-Bluetooth profiles (A2DP/HFP) reached through
/// `IOBluetooth`. Moving the audio route is the entire point of this
/// package (ADR 0002 — sequential handoff means the headset's audio link
/// has to actually leave one host), so the BLE-backed implementation is
/// gone rather than kept alongside this one.
///
/// Devices are resolved from `IOBluetoothDevice.pairedDevices()` — this
/// gateway never pairs and never runs an `IOBluetoothDeviceInquiry`.
/// Per the issue's scope it manages one already-paired headset; pairing
/// and discovery are separate, not-yet-created follow-ups.
///
/// Per ADR 0002 it has no notion of "the other device" either: that
/// policy lives one layer up, in ``BluetoothConnectionManager``.
///
/// ## Main-actor isolation
///
/// `IOBluetooth` delivers `connectionComplete:status:` and its
/// disconnect notifications as run-loop sources on the thread that
/// registered them. A Swift concurrency executor thread has no run loop,
/// so calling `openConnection(_:)` from an arbitrary cooperative thread
/// would leave the callback — and therefore the continuation below —
/// undelivered. Isolating the whole gateway to the main actor both fixes
/// that and removes the need for the manual `NSLock` its CoreBluetooth
/// predecessor used to guard its continuation bookkeeping: actor
/// isolation serializes that instead.
///
/// The host process must therefore be running its main run loop (an
/// `NSApplication`, or `RunLoop.main`/`dispatchMain()` in a CLI). A
/// process that only ever `await`s from a top-level task without running
/// its main run loop will never see these callbacks — see
/// `docs/handoffs/101.md`.
///
/// Not exercised by this package's tests: the CI macOS runner has no
/// Bluetooth hardware, so ``BluetoothConnectionManager``'s tests fake
/// the ``BluetoothPeripheralGateway`` protocol boundary instead of
/// mocking `IOBluetooth`'s own types.
@MainActor
public final class IOBluetoothPeripheralGateway: BluetoothPeripheralGateway {
    /// Receives `IOBluetooth`'s callbacks. Held for the gateway's
    /// lifetime because `IOBluetooth` doesn't retain the targets it's
    /// handed. A separate `NSObject` (rather than making the gateway
    /// itself the target) keeps the continuation bookkeeping isolated
    /// from the gateway's public async API — the same split the
    /// CoreBluetooth implementation used.
    private let callbacks = Callbacks()

    public init() {}

    /// Opens the baseband connection to the paired device encoded in
    /// `deviceIdentifier`, which is what pulls the headset's audio
    /// profiles over to this host. A no-op if it's already connected.
    public func connect(deviceIdentifier: UUID) async throws {
        let device = try resolveDevice(deviceIdentifier)
        guard !device.isConnected() else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            callbacks.addConnectContinuation(for: deviceIdentifier, continuation: continuation)

            let status = device.openConnection(callbacks)
            guard status != kIOReturnSuccess else { return }
            // openConnection failed outright, so connectionComplete will
            // never arrive. Resuming here is safe even if it somehow
            // does: whichever path gets there first takes the
            // continuation out of the dictionary, and the other finds
            // nothing left to resume.
            callbacks.resumeConnect(for: deviceIdentifier) {
                $0.resume(throwing: BluetoothGatewayError.connectFailed(deviceIdentifier, status: status))
            }
        }
    }

    /// Closes the baseband connection to the paired device encoded in
    /// `deviceIdentifier`, releasing the headset to reconnect elsewhere.
    /// A no-op if it isn't currently connected.
    public func disconnect(deviceIdentifier: UUID) async throws {
        let device = try resolveDevice(deviceIdentifier)
        guard device.isConnected() else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            callbacks.addDisconnectContinuation(for: deviceIdentifier, continuation: continuation)

            // Registered before the close call so that a disconnect
            // which completes immediately still resolves the
            // continuation.
            let notification = device.register(
                forDisconnectNotification: callbacks,
                selector: #selector(Callbacks.disconnected(_:fromDevice:))
            )

            let status = device.closeConnection()
            guard status != kIOReturnSuccess else { return }
            // No disconnect is coming, so this one-shot registration
            // would otherwise sit there until the device happens to
            // disconnect for some unrelated reason.
            notification?.unregister()
            callbacks.resumeDisconnect(for: deviceIdentifier) {
                $0.resume(throwing: BluetoothGatewayError.disconnectFailed(deviceIdentifier, status: status))
            }
        }
    }

    private func resolveDevice(_ deviceIdentifier: UUID) throws -> IOBluetoothDevice {
        guard BluetoothDeviceIdentifier.addressString(for: deviceIdentifier) != nil else {
            throw BluetoothGatewayError.unrecognizedDeviceIdentifier(deviceIdentifier)
        }

        let pairedDevices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let device = pairedDevices.first { identifier(of: $0) == deviceIdentifier }
        guard let device else {
            throw BluetoothGatewayError.deviceNotPaired(deviceIdentifier)
        }
        return device
    }

    /// Bridges `IOBluetooth`'s callbacks to the pending
    /// `connect`/`disconnect` continuations above.
    @MainActor
    private final class Callbacks: NSObject {
        private var connectContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
        private var disconnectContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]

        func addConnectContinuation(for identifier: UUID, continuation: CheckedContinuation<Void, Error>) {
            connectContinuations[identifier] = continuation
        }

        func addDisconnectContinuation(for identifier: UUID, continuation: CheckedContinuation<Void, Error>) {
            disconnectContinuations[identifier] = continuation
        }

        func resumeConnect(for identifier: UUID, with body: (CheckedContinuation<Void, Error>) -> Void) {
            guard let continuation = connectContinuations.removeValue(forKey: identifier) else { return }
            body(continuation)
        }

        func resumeDisconnect(for identifier: UUID, with body: (CheckedContinuation<Void, Error>) -> Void) {
            guard let continuation = disconnectContinuations.removeValue(forKey: identifier) else { return }
            body(continuation)
        }

        /// `IOBluetoothDevice.openConnection(_:)`'s completion callback.
        @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
            guard let deviceIdentifier = identifier(of: device) else { return }
            resumeConnect(for: deviceIdentifier) {
                if status == kIOReturnSuccess {
                    $0.resume()
                } else {
                    $0.resume(throwing: BluetoothGatewayError.connectFailed(deviceIdentifier, status: status))
                }
            }
        }

        /// `IOBluetoothDevice.register(forDisconnectNotification:selector:)`'s
        /// callback. The notification is one-shot — `IOBluetooth`
        /// unregisters it once it has been delivered — so it isn't
        /// unregistered here.
        @objc func disconnected(_ notification: IOBluetoothUserNotification, fromDevice device: IOBluetoothDevice) {
            guard let deviceIdentifier = identifier(of: device) else { return }
            resumeDisconnect(for: deviceIdentifier) { $0.resume() }
        }
    }
}

/// The ``BluetoothDeviceIdentifier`` for `device`, derived from its
/// classic-Bluetooth address — the inverse of the address this gateway
/// decodes out of a caller's identifier. `nil` only if `IOBluetooth`
/// reports something that isn't a Bluetooth address, which would leave
/// nothing to match a caller's identifier against.
private func identifier(of device: IOBluetoothDevice) -> UUID? {
    guard let addressString = device.addressString else { return nil }
    return BluetoothDeviceIdentifier.identifier(forAddressString: addressString)
}

#endif
