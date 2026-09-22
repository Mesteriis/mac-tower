import Foundation
import MacTowerCore
import Testing

@testable import MacTowerApp

@Suite("Remote window command cancellation")
@MainActor
struct RemoteWindowCommandTests {
    @Test("Live cancellation preserves a partial native result and prevents later writes")
    func cancellationAfterMutation() async {
        let backend = ControlledWindowMove()
        let (completed, completion) = AsyncStream<WindowMoveResult>.makeStream()
        var replies: [WindowMoveResult] = []
        let command = RemoteWindowCommand(
            request: backend.request,
            cancelOperation: { backend.cancel() },
            completion: { _, result in
                replies.append(result)
                completion.yield(result)
                completion.finish()
            }
        )
        command.start(canStart: { true }, operation: { await backend.move() })
        for await _ in backend.started { break }

        command.cancel()
        #expect(replies.isEmpty)
        #expect(!command.isFinished)
        backend.resume()
        for await result in completed { #expect(result.code == .partial) }

        #expect(command.isFinished)
        #expect(backend.writes == 1)
        #expect(replies.count == 1)
        #expect(replies.first?.requestID == backend.request.id)
        command.cancel()
        #expect(replies.count == 1)
    }

    @Test("Cancellation before the task starts replies immediately without capture or writes")
    func cancellationBeforeStart() {
        let backend = ControlledWindowMove()
        var replies: [WindowMoveResult] = []
        let command = RemoteWindowCommand(
            request: backend.request,
            cancelOperation: { backend.cancel() },
            completion: { _, result in replies.append(result) }
        )
        command.start(canStart: { true }, operation: { await backend.move() })
        command.cancel()

        #expect(command.isFinished)
        #expect(replies.map(\.code) == [.cancelled])
        #expect(backend.writes == 0)
    }

    @Test("Revoked authority before task execution returns cancelled rather than hanging")
    func authorityRevokedBeforeStart() async {
        let backend = ControlledWindowMove()
        let (completed, completion) = AsyncStream<WindowMoveResult>.makeStream()
        let command = RemoteWindowCommand(
            request: backend.request,
            cancelOperation: { backend.cancel() },
            completion: { _, result in
                completion.yield(result)
                completion.finish()
            }
        )
        command.start(canStart: { false }, operation: { await backend.move() })
        for await result in completed { #expect(result.code == .cancelled) }

        #expect(command.isFinished)
        #expect(backend.writes == 0)
    }

    @Test("A cancelled operation that does not finish remains bounded and ignores its late result")
    func cancellationTimeout() async {
        let backend = ControlledWindowMove()
        let (completed, completion) = AsyncStream<WindowMoveResult>.makeStream()
        var replies: [WindowMoveResult] = []
        let command = RemoteWindowCommand(
            request: backend.request,
            cancelOperation: { backend.cancel() },
            completion: { _, result in
                replies.append(result)
                completion.yield(result)
                completion.finish()
            }
        )
        command.start(
            timeout: .milliseconds(20), canStart: { true },
            operation: { await backend.move() }
        )
        for await _ in backend.started { break }
        command.cancel()
        for await result in completed { #expect(result.code == .timeout) }
        #expect(command.isFinished)

        backend.resume()
        for await _ in backend.returned { break }
        #expect(backend.writes == 1)
        #expect(replies.map(\.code) == [.timeout])
    }
}

@MainActor
private final class ControlledWindowMove {
    let request = WindowMoveRequest(displayID: UUID().uuidString, generation: UUID())
    let started: AsyncStream<Void>
    let returned: AsyncStream<Void>
    private let startedSignal: AsyncStream<Void>.Continuation
    private let returnedSignal: AsyncStream<Void>.Continuation
    private var suspended: CheckedContinuation<Void, Never>?
    private var isCancelled = false
    private(set) var writes = 0

    init() {
        (started, startedSignal) = AsyncStream<Void>.makeStream()
        (returned, returnedSignal) = AsyncStream<Void>.makeStream()
    }

    func move() async -> WindowMoveResult {
        writes += 1
        startedSignal.yield()
        startedSignal.finish()
        await withCheckedContinuation { suspended = $0 }
        let cancelled = isCancelled || Task.isCancelled
        if !cancelled { writes += 1 }
        returnedSignal.yield()
        returnedSignal.finish()
        return WindowMoveResult(
            requestID: request.id, displayID: request.displayID,
            code: cancelled ? .partial : .success
        )
    }

    func cancel() { isCancelled = true }

    func resume() {
        suspended?.resume()
        suspended = nil
    }
}
