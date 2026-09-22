import MacTowerCore

extension WindowControlAvailability {
    var displayName: String {
        switch self {
        case .ready: "Ready"
        case .busy: "Moving a window…"
        case .accessibilityRequired: "Accessibility required"
        case .sessionInactive: "Session inactive or locked"
        case .sessionStateUnknown: "Session state unavailable"
        case .unavailable: "Window control unavailable"
        }
    }
}

extension WindowMoveResultCode {
    var displayName: String {
        switch self {
        case .success: "Window moved"
        case .partial: "Window moved only partly"
        case .busy: "Another move is in progress"
        case .noWindow: "No movable active window"
        case .accessibilityRequired: "Accessibility required"
        case .sessionInactive: "Session inactive or locked"
        case .sessionStateUnknown: "Session state unavailable"
        case .targetGone: "Display no longer available"
        case .unsupported: "Window does not support moving"
        case .timeout: "Window move timed out"
        case .cancelled: "Window move cancelled"
        case .unavailable: "Window control unavailable"
        case .invalidCommand: "Window command was rejected"
        }
    }
}
