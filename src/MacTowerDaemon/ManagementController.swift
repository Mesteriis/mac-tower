import Foundation
import MacTowerCore

enum ManagementControllerError: Error {
    case oauthAlreadyInProgress
    case invalidRequest
}

actor ManagementController {
    private let storage: PrivateFileStore
    private let registry: AccountRegistry
    private let codexRoot: URL
    private var configuration: ServiceConfiguration
    private var codexSessions: [AccountID: CodexAccountSession] = [:]
    private var activeLoginAccount: AccountID?
    private var snapshotStore: SnapshotStore?

    init(root: URL) throws {
        storage = try PrivateFileStore(root: root)
        registry = try AccountRegistry(storage: storage)
        codexRoot = root.appending(path: "codex", directoryHint: .isDirectory)
        if let data = try storage.read(named: "service.json") {
            configuration = try ServiceConfiguration.decodeValidated(data)
        } else {
            configuration = try ServiceConfiguration()
        }
    }

    func status() async -> DaemonStatus {
        DaemonStatus(
            running: true,
            httpEnabled: configuration.http.enabled,
            mqttEnabled: configuration.mqtt.enabled,
            configuration: configuration,
            accounts: await registry.all()
        )
    }

    func replaceConfiguration(_ request: ReplaceConfigurationRequest) throws {
        let validated = try ReplaceConfigurationRequest(
            configuration: request.configuration,
            mqttPassword: request.mqttPassword
        )
        var replacement = validated.configuration
        if let password = validated.mqttPassword {
            if password.isEmpty {
                try storage.remove(named: "mqtt-password")
                replacement.mqtt.passwordSecretName = nil
            } else {
                try storage.write(Data(password.utf8), named: "mqtt-password")
                replacement.mqtt.passwordSecretName = "mqtt-password"
            }
        }
        configuration = try replacement.validateForActivation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try storage.write(try encoder.encode(configuration), named: "service.json")
    }

    func addDeepSeek(_ rawRequest: AddDeepSeekAccountRequest) async throws {
        let request = try AddDeepSeekAccountRequest(
            id: rawRequest.id,
            label: rawRequest.label,
            apiKey: rawRequest.apiKey
        )
        let account = try AccountRegistration.deepSeek(id: request.id, label: request.label)
        guard let secretName = account.deepSeekSecretName else {
            throw ManagementControllerError.invalidRequest
        }
        try storage.write(Data(request.apiKey.utf8), named: secretName)
        try await registry.upsert(account)
    }

    func linkClaude(_ rawRequest: LinkClaudeProfileRequest) async throws {
        let request = try LinkClaudeProfileRequest(
            id: rawRequest.id,
            label: rawRequest.label,
            snapshotPath: rawRequest.snapshotPath
        )
        try await registry.upsert(
            try AccountRegistration.claude(
                id: request.id,
                label: request.label,
                snapshotPath: request.snapshotPath
            ))
    }

    func startCodexOAuth(_ rawRequest: StartCodexOAuthRequest) async throws -> CodexOAuthStart {
        let request = try StartCodexOAuthRequest(id: rawRequest.id, label: rawRequest.label)
        guard activeLoginAccount == nil else {
            throw ManagementControllerError.oauthAlreadyInProgress
        }
        let account = try AccountRegistration.codex(id: request.id, label: request.label)
        try await registry.upsert(account)
        activeLoginAccount = request.id

        let home = try ManagedAccountPaths(root: codexRoot).directory(for: request.id)
        let homeStorage = try PrivateFileStore(root: home)
        try homeStorage.write(
            Data("cli_auth_credentials_store = \"file\"\n".utf8),
            named: "config.toml"
        )
        let session = try codexSession(for: account)
        do {
            return try await session.startLogin()
        } catch {
            activeLoginAccount = nil
            throw error
        }
    }

    func removeAccount(_ request: RemoveAccountRequest) async throws {
        if let session = codexSessions.removeValue(forKey: request.id) {
            await session.stop()
        }
        if let account = try await registry.remove(id: request.id),
            let secret = account.deepSeekSecretName
        {
            try storage.remove(named: secret)
        }
    }

    func collectAll(into snapshots: SnapshotStore, at attemptedAt: Date = Date()) async
        -> [AccountSnapshot]
    {
        snapshotStore = snapshots
        let accounts = await registry.all()
        let activeIDs = Set(accounts.map(\.id))
        let previous = await snapshots.all()
        let removed = previous.map(\.snapshot).filter { !activeIDs.contains($0.id) }
        for snapshot in removed {
            await snapshots.remove(accountID: snapshot.id)
        }

        for account in accounts {
            do {
                let snapshot = try await collect(account, at: attemptedAt)
                await snapshots.recordSuccess(snapshot, attemptedAt: attemptedAt)
            } catch {
                if await snapshots.entry(for: account.id) == nil {
                    await snapshots.recordSuccess(
                        unavailableSnapshot(for: account, at: attemptedAt, error: error),
                        attemptedAt: attemptedAt
                    )
                }
                await snapshots.recordFailure(
                    accountID: account.id,
                    attemptedAt: attemptedAt,
                    reason: collectionFailure(for: error)
                )
            }
        }
        return removed
    }

    func stopAllSessions() async {
        let sessions = codexSessions.values
        codexSessions.removeAll()
        activeLoginAccount = nil
        for session in sessions { await session.stop() }
    }

    private func collect(_ account: AccountRegistration, at date: Date) async throws
        -> AccountSnapshot
    {
        switch account.provider {
        case .codex:
            return try await codexSession(for: account).fetchRateLimits(observedAt: date)
        case .claude:
            guard let path = account.claudeSnapshotPath else {
                throw ManagementControllerError.invalidRequest
            }
            return try ClaudeSnapshotFileReader().read(
                from: URL(fileURLWithPath: path),
                expectedID: account.id
            )
        case .deepSeek:
            guard let secretName = account.deepSeekSecretName,
                let data = try storage.read(named: secretName)
            else {
                throw DeepSeekClientError.emptyAPIKey
            }
            let key = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return try await DeepSeekBalanceClient().fetch(
                apiKey: key,
                accountID: account.id,
                label: account.label,
                observedAt: date
            )
        case .cursor:
            throw AccountRegistrationError.unsupportedProvider
        }
    }

    private func codexSession(for account: AccountRegistration) throws -> CodexAccountSession {
        if let session = codexSessions[account.id] { return session }
        let home = try ManagedAccountPaths(root: codexRoot).directory(for: account.id)
        let session = CodexAccountSession(
            accountID: account.id,
            label: account.label,
            configuration: try CodexAppServerProcessConfiguration(
                binaryURL: URL(fileURLWithPath: "/Library/PrivilegedHelperTools/mac-tower-codex"),
                homeURL: home,
                managedAccountsRoot: codexRoot
            )
        ) { [weak self] message in
            Task {
                await self?.handleCodexNotification(for: account.id, message: message)
            }
        }
        codexSessions[account.id] = session
        return session
    }

    private func unavailableSnapshot(
        for account: AccountRegistration,
        at date: Date,
        error: Error
    ) -> AccountSnapshot {
        AccountSnapshot(
            id: account.id,
            provider: account.provider,
            label: account.label,
            status: collectionFailure(for: error) == .authorization
                ? .authorizationRequired : .unavailable,
            source: source(for: account.provider),
            observedAt: date
        )
    }

    private func source(for provider: AIProvider) -> SnapshotSource {
        switch provider {
        case .codex: .codexAppServer
        case .claude: .claudeStatusline
        case .deepSeek, .cursor: .deepSeekAPI
        }
    }

    private func collectionFailure(for error: Error) -> CollectionFailure {
        if let error = error as? DeepSeekClientError, error == .unauthorized {
            return .authorization
        }
        if let error = error as? CodexAccountSessionError {
            switch error {
            case .rpc: return .authorization
            case .invalidResponse: return .malformedResponse
            }
        }
        if error is SensorParsingError || error is ClaudeSnapshotFileError {
            return .malformedResponse
        }
        return .transport
    }

    private func completeLogin(for id: AccountID) {
        if activeLoginAccount == id { activeLoginAccount = nil }
    }

    private func handleCodexNotification(
        for id: AccountID,
        message: CodexAppServerMessage
    ) async {
        switch message.method {
        case "account/login/completed":
            completeLogin(for: id)
        case "account/rateLimits/updated":
            guard let session = codexSessions[id], let snapshotStore else { return }
            do {
                let now = Date()
                let snapshot = try await session.fetchRateLimits(observedAt: now)
                await snapshotStore.recordSuccess(snapshot, attemptedAt: now)
            } catch {
                await snapshotStore.recordFailure(
                    accountID: id,
                    attemptedAt: Date(),
                    reason: collectionFailure(for: error)
                )
            }
        default:
            break
        }
    }
}
