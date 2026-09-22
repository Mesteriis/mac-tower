import Foundation
import MacTowerCore

enum CodexAccountSessionError: Error {
    case rpc(Int)
    case invalidResponse
}

actor CodexAccountSession {
    typealias NotificationHandler = @Sendable (CodexAppServerMessage) -> Void

    private let accountID: AccountID
    private let label: String
    private let process: CodexAppServerProcess
    private let factory = CodexAppServerRequestFactory()
    private let notificationHandler: NotificationHandler
    private var started = false
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<CodexAppServerMessage, Error>] = [:]

    init(
        accountID: AccountID,
        label: String,
        configuration: CodexAppServerProcessConfiguration,
        notificationHandler: @escaping NotificationHandler
    ) {
        self.accountID = accountID
        self.label = label
        process = CodexAppServerProcess(configuration: configuration)
        self.notificationHandler = notificationHandler
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
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: CodexAppServerProcessError.notRunning)
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
            pending[id] = continuation
            do {
                try process.send(frame)
            } catch {
                pending.removeValue(forKey: id)
                process.stop()
                started = false
                continuation.resume(throwing: error)
            }
        }
    }

    private func receive(_ data: Data) {
        guard let message = try? CodexAppServerMessageParser().parse(data) else { return }
        if let id = message.id, let continuation = pending.removeValue(forKey: id) {
            if let error = message.error {
                continuation.resume(throwing: CodexAccountSessionError.rpc(error.code))
            } else {
                continuation.resume(returning: message)
            }
        } else if message.method != nil {
            notificationHandler(message)
        }
    }

    private func processTerminated() {
        started = false
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: CodexAppServerProcessError.notRunning)
        }
    }
}
