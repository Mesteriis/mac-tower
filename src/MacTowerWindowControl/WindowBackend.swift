import Foundation
import MacTowerCore

struct WindowReference: Hashable, Sendable {
    let id: UUID
    init(id: UUID = UUID()) { self.id = id }
}

struct ControlledWindowState: Sendable {
    var frame: WindowRect
    var fullScreen: Bool?
    var canSetFullScreen: Bool
    var canMove: Bool
    var canResize: Bool
}

enum WindowBackendError: Error {
    case noWindow
    case unsupported
    case timeout
    case unavailable
    case sessionInactive
    case sessionStateUnknown
    case accessibilityRequired
}

protocol WindowBackend: Sendable {
    func capture(pid: Int32, deadline: ContinuousClock.Instant) async throws -> WindowReference
    func state(of window: WindowReference, deadline: ContinuousClock.Instant) async throws
        -> ControlledWindowState
    func setFullScreen(_ value: Bool, window: WindowReference, deadline: ContinuousClock.Instant)
        async throws
    func setSize(_ frame: WindowRect, window: WindowReference, deadline: ContinuousClock.Instant)
        async throws
    func setPosition(
        _ frame: WindowRect, window: WindowReference, deadline: ContinuousClock.Instant)
        async throws
    func release(_ window: WindowReference) async
}

struct WindowEnvironment {
    var displays: [WindowDisplay]
    var availability: WindowControlAvailability
}
