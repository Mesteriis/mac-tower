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
    @Published private(set) var powerPresentation = PowerModePresentationState()
    @Published var errorMessage: String?
    @Published private(set) var notificationHistory: [NotificationRecord] = []
    @Published private(set) var panelPairingStatus: NSPanelPairingStatus?
    private let replies = XPCReplyLedger()

    var powerStatus: PowerControlStatus? { powerPresentation.confirmedStatus }
    var isPowerModeBusy: Bool { powerPresentation.pendingMode != nil }

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

    func setPowerMode(_ mode: PowerMode) async {
        guard !isBusy, !isPowerModeBusy else { return }
        isBusy = true
        errorMessage = nil
        let requestID = powerPresentation.begin(mode)
        do {
            let response = try await perform(
                operation: .setPowerMode,
                payload: SetPowerModeRequest(mode: mode),
                response: PowerControlStatus.self
            )
            guard powerPresentation.confirm(response, requestID: requestID) else {
                isBusy = false
                return
            }
            do {
                try await loadStatus()
            } catch {
                errorMessage =
                    "The sleep mode changed, but the service status could not be refreshed."
            }
        } catch {
            let message =
                "Could not confirm the sleep mode. MacTower read the service state without retrying the change."
            _ = powerPresentation.fail(requestID: requestID, message: message)
            errorMessage = message
            try? await loadStatus()
        }
        isBusy = false
    }

    func saveNotificationConfiguration(_ configuration: NotificationConfiguration) async {
        await run {
            _ = try await self.perform(
                operation: .replaceNotificationConfiguration,
                payload: configuration,
                response: EmptyResponse.self
            )
            try await self.loadStatus()
        }
    }

    func loadNotificationHistory(limit: Int = 50, before: NotificationHistoryCursor? = nil) async {
        await run {
            let page = try await self.perform(
                operation: .notificationHistory,
                payload: try NotificationHistoryRequest(limit: limit, before: before),
                response: NotificationHistoryPage.self
            )
            self.notificationHistory = page.records
        }
    }

    func acknowledgeNotification(eventID: UUID) async {
        await run {
            _ = try await self.perform(
                operation: .acknowledgeNotification,
                payload: AcknowledgeNotificationRequest(eventID: eventID),
                response: EmptyResponse.self
            )
            try await self.loadStatus()
        }
    }

    func pairNSPanel() async {
        await run {
            self.panelPairingStatus = try await self.perform(
                operation: .pairNSPanel,
                response: NSPanelPairingStatus.self
            )
            try await self.loadStatus()
        }
    }

    func clearNSPanelToken() async {
        await run {
            _ = try await self.perform(
                operation: .clearNSPanelToken,
                response: EmptyResponse.self
            )
            self.panelPairingStatus = nil
            try await self.loadStatus()
        }
    }

    func testNotificationChannel(_ channel: NotificationTestChannel) async {
        await run {
            _ = try await self.perform(
                operation: .testNotificationChannel,
                payload: TestNotificationChannelRequest(channel: channel),
                response: NotificationDeliveryState.self
            )
        }
    }

    func stop() {
        replies.disconnect()
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
        let loaded = try await perform(operation: .status, response: DaemonStatus.self)
        status = loaded
        powerPresentation.observe(loaded.powerControl)
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

        let data = try await replies.request(
            timeout: .seconds(3),
            onTimeout: { connection.invalidate() },
            start: { [weak self] requestID in
                guard let self else { return }
                let finishWithError: @Sendable (Error) -> Void = { [weak self] error in
                    Task { @MainActor in
                        self?.replies.finish(requestID, result: .failure(error))
                    }
                }
                guard
                    let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                        finishWithError(DaemonClientError.unavailable)
                    }) as? MacTowerDaemonXPCProtocol
                else {
                    replies.finish(
                        requestID, result: .failure(DaemonClientError.unavailable))
                    return
                }
                proxy.perform(request) { [weak self] data, error in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if error != nil {
                            self.replies.finish(
                                requestID, result: .failure(DaemonClientError.rejected))
                        } else if let data {
                            self.replies.finish(requestID, result: .success(data))
                        } else {
                            self.replies.finish(
                                requestID, result: .failure(DaemonClientError.unavailable))
                        }
                    }
                }
            })
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func makeConnection() throws -> NSXPCConnection {
        let connection = try DaemonConnectionFactory.makeConnection()
        connection.resume()
        return connection
    }
}

extension DaemonClient: NotificationAcknowledging {}

private struct EmptyResponse: Codable {}
