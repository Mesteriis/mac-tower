import Foundation
import MacTowerCore

enum CodexAccountSessionError: Error {
    case rpc(Int)
    case invalidResponse
    case timeout
}

actor CodexAccountSession {
    typealias NotificationHandler = @Sendable (CodexAppServerMessage) -> Void

    private let accountID: AccountID
    private let label: String
    private let process: CodexAppServerProcess
    private let factory = CodexAppServerRequestFactory()
    private let notificationHandler: NotificationHandler
    private let terminationHandler: @Sendable () -> Void
    private var started = false
    private var nextID = 1
    private struct PendingRequest {
        let continuation: CheckedContinuation<CodexAppServerMessage, Error>
        let timeoutTask: Task<Void, Never>
    }

    private var pending: [Int: PendingRequest] = [:]

    init(
        accountID: AccountID,
        label: String,
        configuration: CodexAppServerProcessConfiguration,
        notificationHandler: @escaping NotificationHandler,
        terminationHandler: @escaping @Sendable () -> Void
    ) {
        self.accountID = accountID
        self.label = label
        process = CodexAppServerProcess(configuration: configuration)
        self.notificationHandler = notificationHandler
        self.terminationHandler = terminationHandler
    }

    func startLogin() async throws -> CodexOAuthStart {
        try await ensureStarted()
        let message = try await request { try factory.startChatGPTLogin(id: $0) }
        guard let loginID = message.result?["loginId"]?.stringValue,
            let rawURL = message.result?["authUrl"]?.stringValue,
            let authorizationURL = URL(string: rawURL),
            authorizationURL.scheme == "https"
        else {
            throw CodexAccountSessionError.invalidResponse
        }
        return CodexOAuthStart(loginID: loginID, authorizationURL: authorizationURL)
    }

    func fetchRateLimits(observedAt: Date = Date()) async throws -> AccountSnapshot {
        try await ensureStarted()
        let message = try await request { try factory.rateLimits(id: $0) }
        return try CodexRateLimitsResultDecoder().snapshot(
            from: message,
            accountID: accountID,
            label: label,
            observedAt: observedAt
        )
    }

    func stop() {
        process.stop()
        started = false
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: CodexAppServerProcessError.notRunning)
        }
    }

    private func ensureStarted() async throws {
        guard !started else { return }
        try process.start(
            messageHandler: { [weak self] data in
                Task { await self?.receive(data) }
            },
            terminationHandler: { [weak self] in
                Task { await self?.processTerminated() }
            }
        )
        started = true
        _ = try await request { try factory.initialize(id: $0) }
        try process.send(factory.initialized())
    }

    private func request(
        _ makeFrame: (Int) throws -> Data
    ) async throws -> CodexAppServerMessage {
        let id = nextID
        nextID += 1
        let frame = try makeFrame(id)
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(30), clock: .continuous)
                } catch {
                    return
                }
                await self?.timeOutRequest(id: id)
            }
            pending[id] = PendingRequest(
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            do {
                try process.send(frame)
            } catch {
                pending.removeValue(forKey: id)?.timeoutTask.cancel()
                process.stop()
                started = false
                continuation.resume(throwing: error)
            }
        }
    }

    private func receive(_ data: Data) {
        guard let message = try? CodexAppServerMessageParser().parse(data) else { return }
        if let id = message.id, let request = pending.removeValue(forKey: id) {
            request.timeoutTask.cancel()
            if let error = message.error {
                request.continuation.resume(throwing: CodexAccountSessionError.rpc(error.code))
            } else {
                request.continuation.resume(returning: message)
            }
        } else if message.method != nil {
            notificationHandler(message)
        }
    }

    private func processTerminated() {
        started = false
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: CodexAppServerProcessError.notRunning)
        }
        terminationHandler()
    }

    private func timeOutRequest(id: Int) {
        guard let request = pending.removeValue(forKey: id) else { return }
        process.stop()
        started = false
        request.continuation.resume(throwing: CodexAccountSessionError.timeout)
    }
}
