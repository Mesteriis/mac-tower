import Foundation
import MacTowerCore
import Testing

@testable import MacTowerWindowControl

@MainActor
@Suite("User-session window controller")
struct WindowControllerTests {
    private let primary = WindowDisplay(
        id: "00000000-0000-0000-0000-000000000001", name: "Built-in",
        frame: .init(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: .init(x: 0, y: 40, width: 1440, height: 835), isPrimary: true)
    private let target = WindowDisplay(
        id: "00000000-0000-0000-0000-000000000002", name: "External",
        frame: .init(x: -1920, y: 0, width: 1920, height: 1080),
        visibleFrame: .init(x: -1920, y: 0, width: 1920, height: 1055), isPrimary: false)

    @Test("Normal move uses the chosen display's usable frame, with no focus recapture")
    func normalMove() async {
        let backend = FakeWindowBackend()
        let controller = makeController(backend)
        let result = await controller.move(to: target.id)
        #expect(result.code == .success)
        let state = await backend.currentState
        #expect(state.frame == WindowRect(x: -1920, y: -155, width: 1920, height: 1055))
        #expect(await backend.capturedPIDs == [10])
        #expect(await backend.fullScreenChanges.isEmpty)
    }

    @Test("An app's size constraint is reported as partial, not success")
    func constrainedFrame() async {
        let backend = FakeWindowBackend(constrainSize: true)
        let result = await makeController(backend).move(to: target.id)
        #expect(result.code == .partial)
    }

    @Test("Full screen exits, moves the same window, and restores")
    func fullScreenMove() async {
        let backend = FakeWindowBackend(fullScreen: true)
        let result = await makeController(backend).move(to: target.id)
        #expect(result.code == .success)
        #expect(await backend.fullScreenChanges == [false, true])
        #expect(await backend.capturedPIDs == [10])
    }

    @Test("A split or ambiguous full screen frame is not changed")
    func rejectsSplitView() async {
        let backend = FakeWindowBackend(
            fullScreen: true, frame: .init(x: 0, y: 0, width: 700, height: 900))
        let result = await makeController(backend).move(to: target.id)
        #expect(result.code == .unsupported)
        #expect(await backend.fullScreenChanges.isEmpty)
        #expect(await backend.writeCount == 0)
    }

    @Test("Failure to restore full screen preserves the moved window and reports partial")
    func failedRestore() async {
        let backend = FakeWindowBackend(fullScreen: true, failRestore: true)
        let result = await makeController(backend).move(to: target.id)
        #expect(result.code == .partial)
        #expect(await backend.currentState.fullScreen == false)
    }

    @Test("An exited full screen window that rejects resizing is a partial operation")
    func exitedButCannotResize() async {
        let backend = FakeWindowBackend(fullScreen: true, canResizeAfterExit: false)
        #expect(await makeController(backend).move(to: target.id).code == .partial)
        #expect(await backend.currentState.fullScreen == false)
        #expect(await backend.writeCount == 0)
    }

    @Test("Restoring full screen on the wrong monitor must not report success")
    func fullScreenWrongMonitor() async {
        let backend = FakeWindowBackend(fullScreen: true, restoreToWrongMonitor: true)
        #expect(await makeController(backend).move(to: target.id).code == .partial)
    }

    @Test("An accepted but unconfirmed fullscreen exit is partial and never moves or resizes")
    func failedExit() async {
        let backend = FakeWindowBackend(fullScreen: true, ignoreExit: true)
        let controller = makeController(backend, timeout: .milliseconds(30))
        let result = await controller.move(to: target.id)
        #expect(result.code == .partial)
        #expect(await backend.writeCount == 0)
    }

    @Test(
        "Session loss after an accepted fullscreen exit reports partial and prevents later writes")
    func sessionLossAfterFullScreenExit() async {
        let mutable = MutableWindowEnvironment(displays: [primary, target])
        let backend = FakeWindowBackend(
            fullScreen: true,
            afterFullScreenChange: { value in
                if !value { mutable.availability = .sessionInactive }
            })
        let controller = WindowController(
            backend: backend, environment: { mutable.value }, focusedPID: { 10 })
        #expect(await controller.move(to: target.id).code == .partial)
        #expect(await backend.currentState.fullScreen == false)
        #expect(await backend.fullScreenChanges == [false])
        #expect(await backend.writeCount == 0)
    }

    @Test(
        "Fullscreen exit uses the refreshed work area without cancelling unchanged physical topology"
    )
    func refreshedWorkAreaAfterExit() async {
        let adjusted = WindowDisplay(
            id: target.id, name: target.name, frame: target.frame,
            visibleFrame: .init(x: -1920, y: 40, width: 1920, height: 1000), isPrimary: false)
        let mutable = MutableWindowEnvironment(displays: [primary, target])
        let backend = FakeWindowBackend(
            fullScreen: true,
            afterFullScreenChange: { value in
                if !value { mutable.displays = [primary, adjusted] }
            })
        let controller = WindowController(
            backend: backend, environment: { mutable.value }, focusedPID: { 10 })
        await controller.refresh()
        let generation = controller.snapshot.generation
        #expect(await controller.move(to: target.id).code == .success)
        #expect(
            await backend.ordinaryFrameBeforeRestore
                == WindowRect(x: -1920, y: -140, width: 1920, height: 1000))
        #expect(controller.snapshot.generation == generation)
        #expect(controller.snapshot.displays == [primary, adjusted])
    }

    @Test("A physical frame change during capture cancels before any mutation")
    func physicalTopologyChange() async throws {
        let backend = FakeWindowBackend(captureDelay: .milliseconds(50))
        let mutable = MutableWindowEnvironment(displays: [primary, target])
        let controller = WindowController(
            backend: backend, environment: { mutable.value }, focusedPID: { 10 })
        let operation = Task { await controller.move(to: target.id) }
        try await Task.sleep(for: .milliseconds(5))
        mutable.displays = [
            primary,
            WindowDisplay(
                id: target.id, name: target.name,
                frame: .init(x: 1440, y: 0, width: 1920, height: 1080),
                visibleFrame: .init(x: 1440, y: 0, width: 1920, height: 1055), isPrimary: false),
        ]
        #expect(await operation.value.code == .cancelled)
        #expect(await backend.writeCount == 0)
    }

    @Test("Frame confirmation compares against work area refreshed after the AX read")
    func workAreaChangesDuringReadback() async {
        let adjusted = WindowDisplay(
            id: target.id, name: target.name, frame: target.frame,
            visibleFrame: .init(x: -1920, y: 40, width: 1920, height: 1000), isPrimary: false)
        let mutable = MutableWindowEnvironment(displays: [primary, target])
        let backend = FakeWindowBackend(afterStateRead: { count in
            if count == 3 { mutable.displays = [primary, adjusted] }
        })
        let controller = WindowController(
            backend: backend, environment: { mutable.value }, focusedPID: { 10 })
        #expect(await controller.move(to: target.id).code == .partial)
        #expect(controller.snapshot.displays == [primary, adjusted])
    }

    @Test("Missing permission, inactive sessions, and removed displays deny before capture")
    func preflightDenial() async {
        for (availability, expected) in [
            (
                WindowControlAvailability.accessibilityRequired,
                WindowMoveResultCode.accessibilityRequired
            ), (.sessionInactive, .sessionInactive), (.sessionStateUnknown, .sessionStateUnknown),
        ] {
            let backend = FakeWindowBackend()
            let controller = WindowController(
                backend: backend,
                environment: { .init(displays: [primary, target], availability: availability) },
                focusedPID: { 10 })
            #expect(await controller.move(to: target.id).code == expected)
            #expect(await backend.capturedPIDs.isEmpty)
        }
        let backend = FakeWindowBackend()
        #expect(await makeController(backend).move(to: UUID().uuidString).code == .targetGone)
        #expect(await backend.capturedPIDs.isEmpty)
    }

    @Test("An old remote generation is rejected; local commands need no daemon")
    func generationGuard() async {
        let backend = FakeWindowBackend()
        let controller = makeController(backend)
        await controller.refresh()
        #expect(await controller.move(to: target.id, expectedGeneration: UUID()).code == .cancelled)
        #expect(await backend.capturedPIDs.isEmpty)
        #expect(await controller.move(to: target.id).code == .success)
    }

    @Test("Commands serialize without a backlog")
    func busy() async throws {
        let backend = FakeWindowBackend(captureDelay: .milliseconds(50))
        let controller = makeController(backend)
        let first = Task { await controller.move(to: target.id) }
        try await Task.sleep(for: .milliseconds(5))
        #expect(await controller.move(to: primary.id).code == .busy)
        #expect(await first.value.code == .success)
        #expect(await backend.capturedPIDs == [10])
    }

    @Test("Menu target remains bound to the application captured before clicking")
    func menuCapture() async {
        let backend = FakeWindowBackend()
        let mutable = MutableWindowEnvironment(displays: [primary, target])
        let controller = WindowController(
            backend: backend, environment: { mutable.value }, focusedPID: { mutable.pid })
        controller.captureMenuTarget()
        mutable.pid = 20
        #expect(await controller.move(to: target.id, useMenuTarget: true).code == .success)
        #expect(await backend.capturedPIDs == [10])
    }

    @Test("Menu capture preserves unsupported and timeout outcomes instead of claiming no window")
    func menuCaptureError() async {
        for (error, expected) in [
            (WindowBackendError.unsupported, WindowMoveResultCode.unsupported),
            (.timeout, .timeout),
        ] {
            let backend = FakeWindowBackend(captureError: error)
            let controller = makeController(backend)
            controller.captureMenuTarget()
            #expect(await controller.move(to: target.id, useMenuTarget: true).code == expected)
            #expect(await backend.writeCount == 0)
        }
    }

    @Test("Loss of the remote bridge prevents later mutation stages")
    func remoteCancellation() async throws {
        let backend = FakeWindowBackend(captureDelay: .milliseconds(50))
        let controller = makeController(backend)
        await controller.refresh()
        let generation = controller.snapshot.generation
        let operation = Task {
            await controller.move(to: target.id, expectedGeneration: generation)
        }
        try await Task.sleep(for: .milliseconds(5))
        controller.cancelRemoteOperations()
        #expect(await operation.value.code == .cancelled)
        #expect(await backend.writeCount == 0)
    }

    @Test("A display removed after capture is not replaced with another display")
    func removedDuringOperation() async throws {
        let backend = FakeWindowBackend(captureDelay: .milliseconds(50))
        let mutable = MutableWindowEnvironment(displays: [primary, target])
        let controller = WindowController(
            backend: backend, environment: { mutable.value }, focusedPID: { 10 })
        let operation = Task { await controller.move(to: target.id) }
        try await Task.sleep(for: .milliseconds(5))
        mutable.displays = [primary]
        #expect(await operation.value.code == .targetGone)
        #expect(await backend.writeCount == 0)
    }

    @Test("Session loss while capturing blocks the first write")
    func sessionLossDuringCapture() async throws {
        let backend = FakeWindowBackend(captureDelay: .milliseconds(50))
        let mutable = MutableWindowEnvironment(displays: [primary, target])
        let controller = WindowController(
            backend: backend, environment: { mutable.value }, focusedPID: { 10 })
        let operation = Task { await controller.move(to: target.id) }
        try await Task.sleep(for: .milliseconds(5))
        mutable.availability = .sessionInactive
        #expect(await operation.value.code == .sessionInactive)
        #expect(await backend.writeCount == 0)
    }

    @Test("No external foreground application never falls back to another window")
    func noForegroundApp() async {
        let backend = FakeWindowBackend()
        let controller = WindowController(
            backend: backend,
            environment: { .init(displays: [primary, target], availability: .ready) },
            focusedPID: { nil })
        #expect(await controller.move(to: target.id).code == .noWindow)
        #expect(await backend.capturedPIDs.isEmpty)
    }

    @Test("Cancelling the remote bridge does not cancel a local move")
    func localUnaffectedByBridge() async throws {
        let backend = FakeWindowBackend(captureDelay: .milliseconds(50))
        let controller = makeController(backend)
        let operation = Task { await controller.move(to: target.id) }
        try await Task.sleep(for: .milliseconds(5))
        controller.cancelRemoteOperations()
        #expect(await operation.value.code == .success)
    }

    private func makeController(_ backend: FakeWindowBackend, timeout: Duration = .seconds(20))
        -> WindowController
    {
        WindowController(
            backend: backend,
            environment: { .init(displays: [primary, target], availability: .ready) },
            focusedPID: { 10 }, operationTimeout: timeout)
    }
}

@MainActor
private final class MutableWindowEnvironment {
    var displays: [WindowDisplay]
    var availability = WindowControlAvailability.ready
    var pid: Int32 = 10
    var value: WindowEnvironment { .init(displays: displays, availability: availability) }
    init(displays: [WindowDisplay]) { self.displays = displays }
}

private actor FakeWindowBackend: WindowBackend {
    var currentState: ControlledWindowState
    var capturedPIDs: [Int32] = []
    var fullScreenChanges: [Bool] = []
    var writeCount = 0
    var ordinaryFrameBeforeRestore: WindowRect?
    private var stateReadCount = 0
    private let reference = WindowReference()
    private let constrainSize: Bool
    private let failRestore: Bool
    private let ignoreExit: Bool
    private let captureDelay: Duration
    private let canResizeAfterExit: Bool
    private let restoreToWrongMonitor: Bool
    private let captureError: WindowBackendError?
    private let afterFullScreenChange: (@MainActor @Sendable (Bool) -> Void)?
    private let afterStateRead: (@MainActor @Sendable (Int) -> Void)?

    init(
        fullScreen: Bool = false, frame: WindowRect = .init(x: 0, y: 0, width: 1440, height: 900),
        constrainSize: Bool = false, failRestore: Bool = false, ignoreExit: Bool = false,
        captureDelay: Duration = .zero, canResizeAfterExit: Bool = true,
        restoreToWrongMonitor: Bool = false, captureError: WindowBackendError? = nil,
        afterFullScreenChange: (@MainActor @Sendable (Bool) -> Void)? = nil,
        afterStateRead: (@MainActor @Sendable (Int) -> Void)? = nil
    ) {
        self.currentState = .init(
            frame: frame, fullScreen: fullScreen, canSetFullScreen: true, canMove: true,
            canResize: true)
        self.constrainSize = constrainSize
        self.failRestore = failRestore
        self.ignoreExit = ignoreExit
        self.captureDelay = captureDelay
        self.canResizeAfterExit = canResizeAfterExit
        self.restoreToWrongMonitor = restoreToWrongMonitor
        self.captureError = captureError
        self.afterFullScreenChange = afterFullScreenChange
        self.afterStateRead = afterStateRead
    }
    func capture(pid: Int32, deadline: ContinuousClock.Instant) async throws -> WindowReference {
        capturedPIDs.append(pid)
        if let captureError { throw captureError }
        if captureDelay > .zero { try await Task.sleep(for: captureDelay) }
        return reference
    }
    func state(of window: WindowReference, deadline: ContinuousClock.Instant) async throws
        -> ControlledWindowState
    {
        guard window == reference else { throw WindowBackendError.noWindow }
        stateReadCount += 1
        await afterStateRead?(stateReadCount)
        return currentState
    }
    func setFullScreen(_ value: Bool, window: WindowReference, deadline: ContinuousClock.Instant)
        async throws
    {
        guard window == reference else { throw WindowBackendError.noWindow }
        if value && failRestore { throw WindowBackendError.unsupported }
        fullScreenChanges.append(value)
        if !value && ignoreExit { return }
        currentState.fullScreen = value
        if !value { currentState.canResize = canResizeAfterExit }
        if value {
            ordinaryFrameBeforeRestore = currentState.frame
            currentState.frame =
                restoreToWrongMonitor
                ? .init(x: 0, y: 0, width: 1440, height: 900)
                : .init(x: -1920, y: -180, width: 1920, height: 1080)
        }
        await afterFullScreenChange?(value)
    }
    func setSize(_ frame: WindowRect, window: WindowReference, deadline: ContinuousClock.Instant) {
        writeCount += 1
        if !constrainSize {
            currentState.frame.width = frame.width
            currentState.frame.height = frame.height
        }
    }
    func setPosition(
        _ frame: WindowRect, window: WindowReference, deadline: ContinuousClock.Instant
    ) {
        writeCount += 1
        currentState.frame.x = frame.x
        currentState.frame.y = frame.y
    }
    func release(_ window: WindowReference) {}
}
