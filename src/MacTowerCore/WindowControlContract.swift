import Foundation

public struct WindowRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
}

public struct WindowDisplay: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let frame: WindowRect
    public let visibleFrame: WindowRect
    public let isPrimary: Bool

    public init(
        id: String, name: String, frame: WindowRect, visibleFrame: WindowRect, isPrimary: Bool
    ) {
        self.id = id
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isPrimary = isPrimary
    }
}

/// Dock/menu work areas can change without a monitor being connected, moved or scaled.
public enum WindowTopology {
    public static func matches(_ lhs: [WindowDisplay], _ rhs: [WindowDisplay]) -> Bool {
        guard lhs.count == rhs.count,
            Set(lhs.map(\.id)).count == lhs.count,
            Set(rhs.map(\.id)).count == rhs.count
        else { return false }
        return lhs.allSatisfy { display in
            rhs.contains { other in
                display.id == other.id && display.frame == other.frame
                    && display.isPrimary == other.isPrimary
            }
        }
    }
}

public enum WindowControlAvailability: String, Codable, Sendable {
    case ready
    case busy
    case accessibilityRequired = "accessibility_required"
    case sessionInactive = "session_inactive"
    case sessionStateUnknown = "session_state_unknown"
    case unavailable

    public var isEligible: Bool { self == .ready || self == .busy }
}

public struct WindowAgentSnapshot: Codable, Equatable, Sendable {
    public let generation: UUID
    public let displays: [WindowDisplay]
    public let availability: WindowControlAvailability

    public init(
        generation: UUID, displays: [WindowDisplay], availability: WindowControlAvailability
    ) {
        self.generation = generation
        self.displays = displays
        self.availability = availability
    }

    public func validate() throws {
        guard displays.count <= 32,
            Set(displays.compactMap { UUID(uuidString: $0.id) }).count == displays.count,
            displays.allSatisfy({
                UUID(uuidString: $0.id) != nil && !$0.name.isEmpty && $0.name.count <= 128
                    && $0.frame.isValid && $0.visibleFrame.isValid
            })
        else { throw WindowControlContractError.invalidSnapshot }
    }
}

public struct WindowMoveRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let displayID: String
    public let generation: UUID
    public let epoch: UUID

    public init(id: UUID = UUID(), displayID: String, generation: UUID, epoch: UUID = UUID()) {
        self.id = id
        self.displayID = displayID
        self.generation = generation
        self.epoch = epoch
    }
}

public enum WindowMoveResultCode: String, Codable, Sendable {
    case success
    case partial
    case busy
    case noWindow = "no_window"
    case accessibilityRequired = "accessibility_required"
    case sessionInactive = "session_inactive"
    case sessionStateUnknown = "session_state_unknown"
    case targetGone = "target_gone"
    case unsupported
    case timeout
    case cancelled
    case unavailable
    case invalidCommand = "invalid_command"
}

public struct WindowMoveResult: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let displayID: String
    public let code: WindowMoveResultCode

    public init(requestID: UUID, displayID: String, code: WindowMoveResultCode) {
        self.requestID = requestID
        self.displayID = displayID
        self.code = code
    }
}

public struct WindowBridgeStatus: Codable, Sendable {
    public let enabled: Bool
    public let epoch: UUID

    public init(enabled: Bool, epoch: UUID) {
        self.enabled = enabled
        self.epoch = epoch
    }
}

public enum WindowControlContractError: Error {
    case invalidSnapshot
}

@objc public protocol MacTowerWindowAgentXPCProtocol {
    func moveActiveWindow(
        _ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    func cancelRemoteWindowCommands()
    func deliverUserNotification(
        _ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
    func removeUserNotification(
        _ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void)
}
