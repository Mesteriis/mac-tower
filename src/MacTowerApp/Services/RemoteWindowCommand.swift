import Foundation
import MacTowerCore

/// Keeps a live callback until the native operation reports what actually happened.
/// Cancellation after a write may be partial; only a lost connection or deadline
/// ends the callback without waiting for that native result.
@MainActor
final class RemoteWindowCommand {
    let id = UUID()
    private(set) var isFinished = false
    private let request: WindowMoveRequest
    private let cancelOperation: @MainActor () -> Void
    private var completion: (@MainActor (UUID, WindowMoveResult) -> Void)?
    private var task: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var hasStarted = false

    init(
        request: WindowMoveRequest,
        cancelOperation: @escaping @MainActor () -> Void,
        completion: @escaping @MainActor (UUID, WindowMoveResult) -> Void
    ) {
        self.request = request
        self.cancelOperation = cancelOperation
        self.completion = completion
    }

    func start(
        timeout: Duration = .seconds(21),
        canStart: @escaping @MainActor () -> Bool,
        operation: @escaping @MainActor () async -> WindowMoveResult
    ) {
        guard task == nil, !isFinished else { return }
        task = Task { [weak self] in
            guard let self, !self.isFinished else { return }
            guard !Task.isCancelled, canStart() else {
                self.finish(self.result(.cancelled))
                return
            }
            self.hasStarted = true
            let result = await operation()
            self.finish(result)
        }
        timer = Task { [weak self] in
            do { try await Task.sleep(for: timeout, clock: .continuous) } catch { return }
            self?.terminate(code: .timeout)
        }
    }

    func cancel() {
        guard !isFinished else { return }
        cancelOperation()
        task?.cancel()
        if !hasStarted { finish(result(.cancelled)) }
    }

    func terminate(code: WindowMoveResultCode) {
        guard !isFinished else { return }
        cancelOperation()
        task?.cancel()
        finish(result(code))
    }

    private func result(_ code: WindowMoveResultCode) -> WindowMoveResult {
        WindowMoveResult(requestID: request.id, displayID: request.displayID, code: code)
    }

    private func finish(_ result: WindowMoveResult) {
        guard !isFinished else { return }
        isFinished = true
        timer?.cancel()
        timer = nil
        task = nil
        let reply = completion
        completion = nil
        reply?(id, result)
    }
}
