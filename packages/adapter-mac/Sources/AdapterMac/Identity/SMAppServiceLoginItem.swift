#if canImport(ServiceManagement)

import Foundation
import ServiceManagement

/// Real ``LoginItemController``, backed by `SMAppService.mainApp`
/// (macOS 13+, which this package already targets).
///
/// `SMAppService` is the supported replacement for the deprecated
/// `SMLoginItemSetEnabled` and the older `LSSharedFileList` login-item
/// APIs. `mainApp` registers *this* bundle, so nothing extra has to be
/// embedded or installed.
///
/// Not exercised by this package's tests: every call mutates real system
/// state (the user's Login Items list) and needs a real `.app` bundle at
/// a stable path, neither of which a unit test can provide. ``LoginItem``
/// holds the decisions; this is just the boundary.
public struct SMAppServiceLoginItem: LoginItemController {
    public init() {}

    public func currentState() -> LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

#endif
