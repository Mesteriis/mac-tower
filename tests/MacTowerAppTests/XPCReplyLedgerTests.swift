import Foundation
import Testing

@testable import MacTowerApp

@Suite("GUI XPC reply lifetime")
@MainActor
struct XPCReplyLedgerTests {
    @Test("Only the first reply resumes the request")
    func duplicateReply() async throws {
        let replies = XPCReplyLedger()
        let expected = Data("ok".utf8)
        let result = try await replies.request(
            timeout: .seconds(1),
            onTimeout: {
                Issue.record("A completed request must not time out")
            },
            start: { id in
                #expect(replies.finish(id, result: .success(expected)))
                #expect(!replies.finish(id, result: .failure(XPCReplyError.disconnected)))
            }
        )
        #expect(result == expected)
        #expect(replies.count == 0)
    }

    @Test("A missing reply times out and a late reply is ignored")
    func timeout() async {
        let replies = XPCReplyLedger()
        var requestID: UUID?
        var timeoutCount = 0
        await #expect(throws: XPCReplyError.timeout) {
            try await replies.request(
                timeout: .milliseconds(10), onTimeout: { timeoutCount += 1 },
                start: { requestID = $0 }
            )
        }
        #expect(timeoutCount == 1)
        #expect(replies.count == 0)
        if let requestID { #expect(!replies.finish(requestID, result: .success(Data()))) }
    }

    @Test("Disconnect releases all pending requests")
    func disconnect() async {
        let replies = XPCReplyLedger()
        func pendingRequest() async -> Bool {
            do {
                _ = try await replies.request(
                    timeout: .seconds(1),
                    onTimeout: {
                        Issue.record("Disconnect must finish requests before timeout")
                    },
                    start: { _ in
                        if replies.count == 2 { replies.disconnect() }
                    }
                )
                return false
            } catch {
                return (error as? XPCReplyError) == .disconnected
            }
        }
        let first = Task { await pendingRequest() }
        let second = Task { await pendingRequest() }
        #expect(await first.value)
        #expect(await second.value)
        #expect(replies.count == 0)
    }

    @Test("Cancelling a waiting task releases its continuation")
    func cancellation() async {
        let replies = XPCReplyLedger()
        let (started, continuation) = AsyncStream<Void>.makeStream()
        var requestID: UUID?
        let task = Task {
            try await replies.request(
                timeout: .seconds(1),
                onTimeout: {
                    Issue.record("Cancellation must finish before timeout")
                },
                start: { id in
                    requestID = id
                    continuation.yield()
                    continuation.finish()
                }
            )
        }
        for await _ in started { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(replies.count == 0)
        if let requestID { #expect(!replies.finish(requestID, result: .success(Data()))) }
    }
}
