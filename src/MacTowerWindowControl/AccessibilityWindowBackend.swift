import ApplicationServices
import Foundation
import MacTowerCore

/// AX IPC never runs on MainActor. Every message is individually bounded by the operation deadline.
actor AccessibilityWindowBackend: WindowBackend {
    private var windows: [WindowReference: AXUIElement] = [:]
    private let fullScreenAttribute = "AXFullScreen" as CFString

    func capture(pid: Int32, deadline: ContinuousClock.Instant) throws -> WindowReference {
        guard pid > 0, pid != getpid() else { throw WindowBackendError.noWindow }
        let application = AXUIElementCreateApplication(pid)
        let value = try read(application, kAXFocusedWindowAttribute as CFString, deadline: deadline)
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw WindowBackendError.noWindow
        }
        let window = value as! AXUIElement
        var actualPID: pid_t = 0
        guard AXUIElementGetPid(window, &actualPID) == .success, actualPID == pid else {
            throw WindowBackendError.noWindow
        }
        try validateWindow(window, deadline: deadline)
        let reference = WindowReference()
        windows[reference] = window
        return reference
    }

    func state(of reference: WindowReference, deadline: ContinuousClock.Instant) throws
        -> ControlledWindowState
    {
        let window = try element(reference)
        try validateWindow(window, deadline: deadline)
        let position = try read(window, kAXPositionAttribute as CFString, deadline: deadline)
        let size = try read(window, kAXSizeAttribute as CFString, deadline: deadline)
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(),
            CFGetTypeID(size) == AXValueGetTypeID()
        else {
            throw WindowBackendError.unsupported
        }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
            AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
        else {
            throw WindowBackendError.unsupported
        }
        let frame = WindowRect(
            x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)
        guard frame.isValid else { throw WindowBackendError.unsupported }
        return ControlledWindowState(
            frame: frame,
            fullScreen: boolean(try read(window, fullScreenAttribute, deadline: deadline)),
            canSetFullScreen: try isSettable(window, fullScreenAttribute, deadline: deadline),
            canMove: try isSettable(window, kAXPositionAttribute as CFString, deadline: deadline),
            canResize: try isSettable(window, kAXSizeAttribute as CFString, deadline: deadline)
        )
    }

    func setFullScreen(
        _ value: Bool, window reference: WindowReference, deadline: ContinuousClock.Instant
    ) throws {
        let window = try element(reference)
        try prepareMutation(window, deadline: deadline)
        try check(
            AXUIElementSetAttributeValue(
                window, fullScreenAttribute, value ? kCFBooleanTrue : kCFBooleanFalse))
    }

    func setSize(
        _ frame: WindowRect, window reference: WindowReference, deadline: ContinuousClock.Instant
    ) throws {
        let window = try element(reference)
        var size = CGSize(width: frame.width, height: frame.height)
        guard frame.isValid, let value = AXValueCreate(.cgSize, &size) else {
            throw WindowBackendError.unsupported
        }
        try prepareMutation(window, deadline: deadline)
        try check(AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value))
    }

    func setPosition(
        _ frame: WindowRect, window reference: WindowReference, deadline: ContinuousClock.Instant
    ) throws {
        let window = try element(reference)
        var point = CGPoint(x: frame.x, y: frame.y)
        guard frame.isValid, let value = AXValueCreate(.cgPoint, &point) else {
            throw WindowBackendError.unsupported
        }
        try prepareMutation(window, deadline: deadline)
        try check(AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value))
    }

    func release(_ reference: WindowReference) { windows.removeValue(forKey: reference) }

    private func element(_ reference: WindowReference) throws -> AXUIElement {
        guard let window = windows[reference] else { throw WindowBackendError.noWindow }
        return window
    }

    private func validateWindow(_ window: AXUIElement, deadline: ContinuousClock.Instant) throws {
        let role = try read(window, kAXRoleAttribute as CFString, deadline: deadline) as? String
        let subrole =
            try read(window, kAXSubroleAttribute as CFString, deadline: deadline) as? String
        let minimized = boolean(
            try read(window, kAXMinimizedAttribute as CFString, deadline: deadline))
        guard role == kAXWindowRole, subrole == kAXStandardWindowSubrole, minimized == false else {
            throw WindowBackendError.unsupported
        }
    }

    private func read(
        _ element: AXUIElement, _ attribute: CFString, deadline: ContinuousClock.Instant
    ) throws -> CFTypeRef? {
        try prepare(element, deadline: deadline)
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &result)
        if error == .attributeUnsupported || error == .noValue { return nil }
        try check(error)
        return result
    }

    private func isSettable(
        _ element: AXUIElement, _ attribute: CFString, deadline: ContinuousClock.Instant
    ) throws -> Bool {
        try prepare(element, deadline: deadline)
        var result = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, attribute, &result)
        if error == .attributeUnsupported || error == .noValue { return false }
        try check(error)
        return result.boolValue
    }

    private func prepare(_ element: AXUIElement, deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw WindowBackendError.timeout }
        let seconds =
            Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
        try check(AXUIElementSetMessagingTimeout(element, Float(min(0.25, seconds))))
    }

    private func prepareMutation(_ element: AXUIElement, deadline: ContinuousClock.Instant) throws {
        // Recheck immediately on this executor too: a queued AX read must not create a stale lock lease.
        switch SessionGate.current() {
        case .ready: break
        case .sessionStateUnknown: throw WindowBackendError.sessionStateUnknown
        default: throw WindowBackendError.sessionInactive
        }
        guard AXIsProcessTrusted() else { throw WindowBackendError.accessibilityRequired }
        try prepare(element, deadline: deadline)
    }

    private func boolean(_ value: CFTypeRef?) -> Bool? {
        guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFEqual(value, kCFBooleanTrue)
    }

    private func check(_ error: AXError) throws {
        switch error {
        case .success: return
        case .invalidUIElement: throw WindowBackendError.noWindow
        case .cannotComplete: throw WindowBackendError.timeout
        case .attributeUnsupported, .actionUnsupported, .notImplemented:
            throw WindowBackendError.unsupported
        default: throw WindowBackendError.unavailable
        }
    }
}
