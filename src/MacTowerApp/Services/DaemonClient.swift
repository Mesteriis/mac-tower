import Darwin
import Foundation
import MacTowerCore

enum DaemonClientError: LocalizedError {
    case serviceNotInstalled
    case invalidTrustManifest
    case unavailable
    case rejected

    var errorDescription: String? {
        switch self {
        case .serviceNotInstalled: "The MacTower service is not installed. Run make install."
        case .invalidTrustManifest: "The installed service trust manifest is invalid."
        case .unavailable: "The MacTower service is unavailable."
        case .rejected: "The MacTower service rejected the request."
        }
    }
}

@MainActor
final class DaemonClient: ObservableObject {
    @Published private(set) var status: DaemonStatus?
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    func refresh() async {
        await run {
            try await self.loadStatus()
        }
    }

    func addDeepSeek(id: String, label: String, apiKey: String) async {
        await run {
            let request = try AddDeepSeekAccountRequest(
                id: AccountID(id), label: label, apiKey: apiKey)
            _ = try await self.perform(
                operation: .addDeepSeekAccount,
                payload: request,
                response: EmptyResponse.self
            )
            try await self.loadStatus()
        }
    }

    func startCodex(id: String, label: String) async -> URL? {
        var url: URL?
        await run {
            let request = try StartCodexOAuthRequest(id: AccountID(id), label: label)
            url = try await self.perform(
                operation: .startCodexOAuth,
                payload: request,
                response: CodexOAuthStart.self
            ).authorizationURL
            try await self.loadStatus()
        }
        return url
    }

    func cancelCodexOAuth(id: AccountID) async {
        await run {
            _ = try await self.perform(
                operation: .cancelCodexOAuth,
                payload: CancelCodexOAuthRequest(id: id),
                response: EmptyResponse.self
            )
            try await self.loadStatus()
        }
    }

    func linkClaude(
        id: String,
        label: String,
        configDirectory: String,
        snapshotPath: String
    ) async {
        await run {
            let installer = ClaudeStatuslineInstaller()
            let configURL = URL(fileURLWithPath: configDirectory, isDirectory: true)
            let previousState = try installer.captureState(configDirectory: configURL)
            let snapshotURL = URL(fileURLWithPath: snapshotPath).standardizedFileURL
            let installedSnapshot = try installer.install(
                configDirectory: configURL,
                accountID: AccountID(id),
                label: label,
                outputDirectory: snapshotURL.deletingLastPathComponent(),
                bridgeURL: URL(
                    fileURLWithPath: "/Library/PrivilegedHelperTools/mac-tower-claude-bridge")
            )
            do {
                guard installedSnapshot == snapshotURL else {
                    throw AccountRegistrationError.invalidPath
                }
                let request = try LinkClaudeProfileRequest(
                    id: AccountID(id), label: label, snapshotPath: snapshotPath)
                _ = try await self.perform(
                    operation: .linkClaudeProfile,
                    payload: request,
                    response: EmptyResponse.self
                )
            } catch let operationError {
                try installer.restore(previousState, configDirectory: configURL)
                throw operationError
            }
            try await self.loadStatus()
        }
    }

    func restoreClaudeStatusline(configDirectory: String) async {
        await run {
            try ClaudeStatuslineInstaller().uninstall(
                configDirectory: URL(fileURLWithPath: configDirectory, isDirectory: true))
        }
    }

    func save(configuration: ServiceConfiguration, mqttPassword: String?) async {
        await run {
            let request = try ReplaceConfigurationRequest(
                configuration: configuration,
                mqttPassword: mqttPassword
            )
            _ = try await self.perform(
                operation: .replaceConfiguration,
                payload: request,
                response: EmptyResponse.self
            )
            try await self.loadStatus()
        }
    }

    func remove(_ id: AccountID) async {
        await run {
            _ = try await self.perform(
                operation: .removeAccount,
                payload: RemoveAccountRequest(id: id),
                response: EmptyResponse.self
            )
            try await self.loadStatus()
        }
    }

    private func run(_ body: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        do {
            try await body()
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    private func loadStatus() async throws {
        status = try await perform(operation: .status, response: DaemonStatus.self)
    }

    private func perform<Response: Decodable>(
        operation: ManagementOperation,
        response: Response.Type
    ) async throws -> Response {
        try await performData(operation: operation, payload: nil, response: response)
    }

    private func perform<Payload: Encodable, Response: Decodable>(
        operation: ManagementOperation,
        payload: Payload,
        response: Response.Type
    ) async throws -> Response {
        try await performData(
            operation: operation,
            payload: try JSONEncoder().encode(payload),
            response: response
        )
    }

    private func performData<Response: Decodable>(
        operation: ManagementOperation,
        payload: Data?,
        response: Response.Type
    ) async throws -> Response {
        let request = try JSONEncoder().encode(
            ManagementEnvelope(operation: operation, payload: payload))
        let connection = try makeConnection()
        defer { connection.invalidate() }

        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate(continuation)
            guard
                let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                    gate.resume(throwing: DaemonClientError.unavailable)
                }) as? MacTowerDaemonXPCProtocol
            else {
                gate.resume(throwing: DaemonClientError.unavailable)
                return
            }
            proxy.perform(request) { data, error in
                if error != nil {
                    gate.resume(throwing: DaemonClientError.rejected)
                } else if let data {
                    gate.resume(returning: data)
                } else {
                    gate.resume(throwing: DaemonClientError.unavailable)
                }
            }
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func makeConnection() throws -> NSXPCConnection {
        let connection = try DaemonConnectionFactory.makeConnection()
        connection.resume()
        return connection
    }
}

private struct EmptyResponse: Codable {}

private final class ContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let value = continuation
        continuation = nil
        return value
    }
}
