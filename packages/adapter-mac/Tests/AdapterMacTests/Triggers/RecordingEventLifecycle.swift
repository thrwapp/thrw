import Foundation

@testable import AdapterMac

/// Records every `emitEvent`/`endEvent` call instead of publishing
/// anything real - mirrors `adapter-android`'s
/// `RecordingEventLifecycle.kt` fixture.
final class RecordingEventLifecycle: EventLifecycle, @unchecked Sendable {
    struct Emitted: Equatable {
        let type: EventKind
        let priority: Priority
    }

    private(set) var emitted: [Emitted] = []
    private(set) var ended: [EventKind] = []

    func emitEvent(type: EventKind, priority: Priority) async throws {
        emitted.append(Emitted(type: type, priority: priority))
    }

    func endEvent(type: EventKind) async throws {
        ended.append(type)
    }
}
