import AppKit
import ApplicationServices
import Combine
import Foundation
import MacTowerCore

@MainActor
public final class WindowController: ObservableObject {
    @Published public private(set) var snapshot = WindowAgentSnapshot(
        generation: UUID(), displays: [], availability: .unavailable)
    @Published public private(set) var lastResult: WindowMoveResult?

    private let backend: any WindowBackend
    private let environment: @MainActor () -> WindowEnvironment
    private let focusedPID: @MainActor () -> Int32?
    private let menuFocusedPID: @MainActor () -> Int32?
    private let operationTimeout: Duration
    private var activeOperation: UUID?
    private var remoteEpoch = UUID()
    private var menuCapture: Task<Result<WindowReference, WindowBackendError>, Never>?
    private var menuCapturedAt: ContinuousClock.Instant?
    private var observer: Task<Void, Never>?

    public convenience init() {
        let focus = FrontmostApplicationTracker()
        self.init(
            backend: AccessibilityWindowBackend(),
            environment: { NativeWindowEnvironment.capture() },
            focusedPID: { focus.focusedPID(allowMenuFallback: false) },
            menuFocusedPID: { focus.focusedPID(allowMenuFallback: true) }
        )
    }

    init(
        backend: any WindowBackend, environment: @escaping @MainActor () -> WindowEnvironment,
        focusedPID: @escaping @MainActor () -> Int32?, operationTimeout: Duration = .seconds(20),
        menuFocusedPID: (@MainActor () -> Int32?)? = nil
    ) {
        self.backend = backend
        self.environment = environment
        self.focusedPID = focusedPID
        self.menuFocusedPID = menuFocusedPID ?? focusedPID
        self.operationTimeout = min(operationTimeout, .seconds(20))
    }

    deinit {
        observer?.cancel()
        menuCapture?.cancel()
    }

    public func start() {
        guard observer == nil else { return }
        // Polling also notices TCC changes and lock transitions that have no public notification.
        observer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    public func requestAccessibilityPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        Task { await refresh() }
    }

    public func refresh() async {
        refreshSnapshot()
    }

    public func captureMenuTarget() {
        releaseMenuCapture()
        refreshSnapshot()
        guard snapshot.availability == .ready, let pid = menuFocusedPID() else { return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let backend = backend
        menuCapturedAt = .now
        menuCapture = Task {
            do {
                let window = try await backend.capture(pid: pid, deadline: deadline)
                guard !Task.isCancelled else {
                    await backend.release(window)
                    return .failure(.unavailable)
                }
                return .success(window)
            } catch {
                return .failure(error as? WindowBackendError ?? .unavailable)
            }
        }
    }

    public func cancelRemoteOperations() {
        // Does not invalidate the local menu operation or force generation churn on every heartbeat.
        remoteEpoch = UUID()
    }

    public func move(
        to displayID: String, useMenuTarget: Bool = false, requestID: UUID = UUID(),
        expectedGeneration: UUID? = nil
    ) async -> WindowMoveResult {
        func finish(_ code: WindowMoveResultCode) -> WindowMoveResult {
            let result = WindowMoveResult(requestID: requestID, displayID: displayID, code: code)
            lastResult = result
            return result
        }
        guard UUID(uuidString: displayID) != nil, !(useMenuTarget && expectedGeneration != nil)
        else {
            return finish(.invalidCommand)
        }
        refreshSnapshot()
        guard expectedGeneration == nil || expectedGeneration == snapshot.generation else {
            return finish(.cancelled)
        }
        guard activeOperation == nil else { return finish(.busy) }
        guard snapshot.availability == .ready else {
            return finish(resultCode(snapshot.availability))
        }
        guard snapshot.displays.contains(where: { $0.id == displayID }) else {
            return finish(.targetGone)
        }

        activeOperation = requestID
        refreshSnapshot()
        let context = OperationContext(
            displayID: displayID, deadline: .now.advanced(by: operationTimeout),
            remoteEpoch: expectedGeneration == nil ? nil : remoteEpoch,
            generation: snapshot.generation
        )
        var captured: WindowReference?
        let outcome: WindowMoveResultCode
        do {
            if useMenuTarget {
                guard let task = menuCapture, let capturedAt = menuCapturedAt,
                    capturedAt.duration(to: .now) < .seconds(120)
                else { throw OperationError(.noWindow) }
                menuCapture = nil
                menuCapturedAt = nil
                captured = try await task.value.get()
            } else {
                guard let pid = focusedPID() else { throw OperationError(.noWindow) }
                captured = try await backend.capture(pid: pid, deadline: context.deadline)
            }
            guard let captured else { throw OperationError(.noWindow) }
            _ = try check(context)
            outcome = try await transfer(captured, context: context)
        } catch {
            outcome = code(for: error)
        }
        if let captured { await backend.release(captured) }
        activeOperation = nil
        refreshSnapshot()
        return finish(outcome)
    }

    private func transfer(_ window: WindowReference, context: OperationContext) async throws
        -> WindowMoveResultCode
    {
        let state = try await backend.state(of: window, deadline: context.deadline)
        var target = try check(context)
        guard let fullScreen = state.fullScreen else { return .unsupported }
        var changed = false
        do {
            if fullScreen {
                guard state.canSetFullScreen,
                    let primary = snapshot.displays.first(where: \.isPrimary),
                    snapshot.displays.contains(where: {
                        WindowGeometry.matches(
                            state.frame,
                            WindowGeometry.accessibilityRect($0.frame, primaryFrame: primary.frame))
                    })
                else { return .unsupported }
                try await backend.setFullScreen(false, window: window, deadline: context.deadline)
                // Acceptance may have changed the desktop even if observation fails or is cancelled.
                changed = true
                try await waitForFullScreen(false, window: window, context: context)
            }
            _ = try check(context)
            let movable = try await backend.state(of: window, deadline: context.deadline)
            target = try check(context)
            guard movable.canMove, movable.canResize else {
                return changed ? .partial : .unsupported
            }
            try await backend.setSize(target, window: window, deadline: context.deadline)
            changed = true
            target = try check(context)
            try await backend.setPosition(target, window: window, deadline: context.deadline)
            target = try check(context)
            // A resize before and after moving accommodates applications that clamp to the old screen.
            try await backend.setSize(target, window: window, deadline: context.deadline)
            _ = try check(context)
            let actual = try await backend.state(of: window, deadline: context.deadline)
            target = try check(context)
            let fits = WindowGeometry.matches(actual.frame, target)
            if fullScreen {
                // Do not re-enter full screen until the requested ordinary-frame placement is confirmed.
                guard fits else { return .partial }
                _ = try check(context)
                try await backend.setFullScreen(true, window: window, deadline: context.deadline)
                try await waitForFullScreen(true, window: window, context: context)
                _ = try check(context)
                let restored = try await backend.state(of: window, deadline: context.deadline)
                _ = try check(context)
                guard let primary = snapshot.displays.first(where: \.isPrimary),
                    let display = snapshot.displays.first(where: { $0.id == context.displayID }),
                    WindowGeometry.matches(
                        restored.frame,
                        WindowGeometry.accessibilityRect(display.frame, primaryFrame: primary.frame)
                    )
                else {
                    return .partial
                }
            }
            _ = try check(context)
            return fits ? .success : .partial
        } catch {
            // No rollback: another app/Space/user action may have changed the desktop in the meantime.
            return changed ? .partial : code(for: error)
        }
    }

    private func waitForFullScreen(
        _ value: Bool, window: WindowReference, context: OperationContext
    ) async throws {
        let stageDeadline = min(context.deadline, ContinuousClock.now.advanced(by: .seconds(8)))
        while true {
            _ = try check(context)
            guard ContinuousClock.now < stageDeadline else { throw OperationError(.timeout) }
            let state = try await backend.state(of: window, deadline: stageDeadline)
            if state.fullScreen == value { return }
            guard state.fullScreen != nil else { throw OperationError(.unsupported) }
            let pause = min(.milliseconds(100), ContinuousClock.now.duration(to: stageDeadline))
            if pause > .zero { try await Task.sleep(for: pause) }
        }
    }

    private func check(_ context: OperationContext) throws -> WindowRect {
        guard !Task.isCancelled else { throw OperationError(.cancelled) }
        guard ContinuousClock.now < context.deadline else { throw OperationError(.timeout) }
        if let epoch = context.remoteEpoch, epoch != remoteEpoch {
            throw OperationError(.cancelled)
        }
        refreshSnapshot()
        guard snapshot.availability.isEligible else {
            throw OperationError(resultCode(snapshot.availability))
        }
        guard let display = snapshot.displays.first(where: { $0.id == context.displayID }),
            let primary = snapshot.displays.first(where: \.isPrimary)
        else { throw OperationError(.targetGone) }
        // Topology changes may change the coordinate space; never continue with a different layout.
        guard snapshot.generation == context.generation else { throw OperationError(.cancelled) }
        return WindowGeometry.accessibilityRect(display.visibleFrame, primaryFrame: primary.frame)
    }

    private func refreshSnapshot() {
        let current = environment()
        let effective: WindowControlAvailability =
            current.availability == .ready && activeOperation != nil ? .busy : current.availability
        let changed =
            !WindowTopology.matches(current.displays, snapshot.displays)
            || effective.isEligible != snapshot.availability.isEligible
            || (!effective.isEligible && effective != snapshot.availability)
        let next = WindowAgentSnapshot(
            generation: changed ? UUID() : snapshot.generation, displays: current.displays,
            availability: effective)
        if next != snapshot { snapshot = next }
    }

    private func releaseMenuCapture() {
        guard let previous = menuCapture else { return }
        previous.cancel()
        let backend = backend
        Task {
            if case .success(let window) = await previous.value { await backend.release(window) }
        }
        menuCapture = nil
        menuCapturedAt = nil
    }

    private func resultCode(_ availability: WindowControlAvailability) -> WindowMoveResultCode {
        switch availability {
        case .ready: .success
        case .busy: .busy
        case .accessibilityRequired: .accessibilityRequired
        case .sessionInactive: .sessionInactive
        case .sessionStateUnknown: .sessionStateUnknown
        case .unavailable: .unavailable
        }
    }

    private func code(for error: Error) -> WindowMoveResultCode {
        if let error = error as? OperationError { return error.code }
        if error is CancellationError { return .cancelled }
        switch error as? WindowBackendError {
        case .noWindow: return .noWindow
        case .unsupported: return .unsupported
        case .timeout: return .timeout
        case .sessionInactive: return .sessionInactive
        case .sessionStateUnknown: return .sessionStateUnknown
        case .accessibilityRequired: return .accessibilityRequired
        default: return .unavailable
        }
    }
}

private struct OperationContext {
    let displayID: String
    let deadline: ContinuousClock.Instant
    let remoteEpoch: UUID?
    let generation: UUID
}

private struct OperationError: Error {
    let code: WindowMoveResultCode
    init(_ code: WindowMoveResultCode) { self.code = code }
}
