import Foundation

enum XPCReplyError: Error, Equatable {
    case timeout
    case disconnected
}

/// Reply, timeout, disconnect, and task cancellation all consume the same entry.
@MainActor
final class XPCReplyLedger {
    private var pending: [UUID: PendingReply] = [:]
    var count: Int { pending.count }

    func request(
        timeout: Duration,
        onTimeout: @escaping @MainActor () -> Void,
        start: (UUID) -> Void
    ) async throws -> Data {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    if self?.finish(id, result: .failure(XPCReplyError.timeout)) == true {
                        onTimeout()
                    }
                }
                pending[id] = PendingReply(continuation: continuation, timer: timer)
                start(id)
            }
        } onCancel: {
            Task { @MainActor in
                self.finish(id, result: .failure(CancellationError()))
            }
        }
    }

    @discardableResult
    func finish(_ id: UUID, result: Result<Data, Error>) -> Bool {
        guard let reply = pending.removeValue(forKey: id) else { return false }
        reply.timer.cancel()
        reply.continuation.resume(with: result)
        return true
    }

    func disconnect() {
        for id in Array(pending.keys) {
            finish(id, result: .failure(XPCReplyError.disconnected))
        }
    }

    private struct PendingReply {
        let continuation: CheckedContinuation<Data, Error>
        let timer: Task<Void, Never>
    }
}
