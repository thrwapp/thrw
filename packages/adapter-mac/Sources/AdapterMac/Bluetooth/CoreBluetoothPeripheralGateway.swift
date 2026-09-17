import CoreBluetooth
import Foundation

/// Errors ``CoreBluetoothPeripheralGateway`` can throw. Distinct from
/// whatever `Error` CoreBluetooth itself hands back through its delegate
/// callbacks, which is propagated as-is when present.
public enum BluetoothGatewayError: Error, Equatable {
    /// `deviceIdentifier` isn't among the peripherals CoreBluetooth
    /// already knows about (i.e. it isn't paired/previously connected).
    /// This gateway never scans — see the type's documentation.
    case peripheralNotFound(UUID)

    /// CoreBluetooth reported connection failure without an underlying
    /// `Error`.
    case connectFailed(UUID)
}

/// Real CoreBluetooth-backed ``BluetoothPeripheralGateway``, wrapping
/// `CBCentralManager`/`CBPeripheral`'s delegate-callback API behind
/// async/await.
///
/// This resolves `deviceIdentifier` via
/// `CBCentralManager.retrievePeripherals(withIdentifiers:)` rather than
/// scanning — per the issue's acceptance criteria this manages a single
/// already-paired headset, not peripheral discovery.
///
/// Per ADR 0002 (sequential handoff, not multipoint), this only ever
/// manages one peripheral connection at a time — it has no notion of
/// "the other device"; that policy lives one layer up, in
/// ``BluetoothConnectionManager``.
///
/// Not exercised by this package's tests (no Bluetooth hardware on the
/// CI runner) — see ``BluetoothConnectionManager``'s tests, which fake
/// the ``BluetoothPeripheralGateway`` protocol boundary instead.
public final class CoreBluetoothPeripheralGateway: NSObject, BluetoothPeripheralGateway, @unchecked Sendable {
    private let centralManager: CBCentralManager
    private let delegate: Delegate

    public override init() {
        let delegate = Delegate()
        self.delegate = delegate
        self.centralManager = CBCentralManager(delegate: delegate, queue: nil)
        super.init()
    }

    public func connect(deviceIdentifier: UUID) async throws {
        let peripheral = try resolvePeripheral(deviceIdentifier)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.addConnectContinuation(for: peripheral.identifier, continuation: continuation)
            centralManager.connect(peripheral, options: nil)
        }
    }

    public func disconnect(deviceIdentifier: UUID) async throws {
        let peripheral = try resolvePeripheral(deviceIdentifier)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.addDisconnectContinuation(for: peripheral.identifier, continuation: continuation)
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    private func resolvePeripheral(_ deviceIdentifier: UUID) throws -> CBPeripheral {
        guard let peripheral = centralManager.retrievePeripherals(withIdentifiers: [deviceIdentifier]).first else {
            throw BluetoothGatewayError.peripheralNotFound(deviceIdentifier)
        }
        return peripheral
    }

    /// Bridges `CBCentralManagerDelegate`'s callback-based API to the
    /// pending `connect`/`disconnect` continuations above. A separate
    /// `NSObject` (rather than making `CoreBluetoothPeripheralGateway`
    /// itself the delegate) keeps the continuation bookkeeping — the one
    /// part that actually needs a lock, since CoreBluetooth invokes its
    /// delegate on its own queue — isolated from the gateway's public
    /// async API.
    private final class Delegate: NSObject, CBCentralManagerDelegate {
        private let lock = NSLock()
        private var connectContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
        private var disconnectContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]

        func addConnectContinuation(for identifier: UUID, continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            connectContinuations[identifier] = continuation
            lock.unlock()
        }

        func addDisconnectContinuation(for identifier: UUID, continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            disconnectContinuations[identifier] = continuation
            lock.unlock()
        }

        func centralManagerDidUpdateState(_ central: CBCentralManager) {
            // No-op: connect/disconnect are only ever called once a
            // peripheral has already been retrieved, which itself
            // requires the central manager to be usable. If a caller
            // invokes this gateway before Bluetooth is powered on,
            // CoreBluetooth's own connect/cancel calls below are simply
            // ignored, and the pending continuation is left to resolve
            // when/if state changes -- documented as a known gap in the
            // handoff doc rather than guessed at here.
        }

        func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
            resume(&connectContinuations, for: peripheral.identifier) { $0.resume() }
        }

        func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
            resume(&connectContinuations, for: peripheral.identifier) {
                $0.resume(throwing: error ?? BluetoothGatewayError.connectFailed(peripheral.identifier))
            }
        }

        func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
            resume(&disconnectContinuations, for: peripheral.identifier) {
                if let error {
                    $0.resume(throwing: error)
                } else {
                    $0.resume()
                }
            }
        }

        private func resume(
            _ continuations: inout [UUID: CheckedContinuation<Void, Error>],
            for identifier: UUID,
            with body: (CheckedContinuation<Void, Error>) -> Void
        ) {
            lock.lock()
            let continuation = continuations.removeValue(forKey: identifier)
            lock.unlock()
            guard let continuation else { return }
            body(continuation)
        }
    }
}
