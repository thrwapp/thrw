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

    /// #234. Mirrors `MacNode`'s own `activeEvents` closely enough for
    /// ``ManualClaim`` to be tested against it: a trigger is active from
    /// a successful `emitEvent` until an `endEvent`. Insertion order is
    /// preserved for the same reason `ActiveEventSet` preserves it.
    private var active: [EventKind] = []

    func emitEvent(type: EventKind, priority: Priority) async throws {
        emitted.append(Emitted(type: type, priority: priority))
        if !active.contains(type) { active.append(type) }
    }

    func endEvent(type: EventKind) async throws {
        ended.append(type)
        active.removeAll { $0 == type }
    }

    func isEventActive(_ type: EventKind) -> Bool {
        active.contains(type)
    }

    func activeEventKinds() -> [EventKind] {
        active
    }
}
