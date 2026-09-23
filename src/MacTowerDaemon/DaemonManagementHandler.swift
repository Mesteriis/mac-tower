import Foundation
import MacTowerCore
import MacTowerPowerControl

protocol ManagementControlling: Sendable {
    func status() async -> DaemonStatus
    func replaceConfiguration(_ request: ReplaceConfigurationRequest) async throws
    func addDeepSeek(_ request: AddDeepSeekAccountRequest) async throws
    func linkClaude(_ request: LinkClaudeProfileRequest) async throws
    func startCodexOAuth(_ request: StartCodexOAuthRequest) async throws -> CodexOAuthStart
    func cancelCodexOAuth(_ request: CancelCodexOAuthRequest) async
    func removeAccount(_ request: RemoveAccountRequest) async throws
}

protocol PowerControlServicing: Sendable {
    func status() -> PowerControlStatus
    func setMode(_ mode: PowerMode) -> PowerControlStatus
}

extension ManagementController: ManagementControlling {}
extension PowerControlService: PowerControlServicing {}

struct DaemonManagementHandler: Sendable {
    private let controller: any ManagementControlling
    private let power: any PowerControlServicing
    private let notifications: (any NotificationServiceControlling)?

    init(
        controller: any ManagementControlling,
        power: any PowerControlServicing,
        notifications: (any NotificationServiceControlling)? = nil
    ) {
        self.controller = controller
        self.power = power
        self.notifications = notifications
    }

    func handle(_ data: Data) async throws -> Data {
        guard data.count <= 1_048_576 else { throw ManagementControllerError.invalidRequest }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let envelope = try decoder.decode(ManagementEnvelope.self, from: data)
        switch envelope.operation {
        case .status:
            let base = await controller.status()
            return try encoder.encode(
                DaemonStatus(
                    running: base.running,
                    httpEnabled: base.httpEnabled,
                    mqttEnabled: base.mqttEnabled,
                    configuration: base.configuration,
                    accounts: base.accounts,
                    activeCodexOAuthAccountID: base.activeCodexOAuthAccountID,
                    powerControl: power.status(),
                    notificationSummary: await notifications?.summary()
                ))
        case .replaceConfiguration:
            try await controller.replaceConfiguration(
                try decoder.decode(
                    ReplaceConfigurationRequest.self, from: requiredPayload(envelope)))
            return Data("{}".utf8)
        case .addDeepSeekAccount:
            try await controller.addDeepSeek(
                try decoder.decode(
                    AddDeepSeekAccountRequest.self, from: requiredPayload(envelope)))
            return Data("{}".utf8)
        case .startCodexOAuth:
            return try encoder.encode(
                try await controller.startCodexOAuth(
                    try decoder.decode(
                        StartCodexOAuthRequest.self, from: requiredPayload(envelope))))
        case .cancelCodexOAuth:
            await controller.cancelCodexOAuth(
                try decoder.decode(
                    CancelCodexOAuthRequest.self, from: requiredPayload(envelope)))
            return Data("{}".utf8)
        case .linkClaudeProfile:
            try await controller.linkClaude(
                try decoder.decode(
                    LinkClaudeProfileRequest.self, from: requiredPayload(envelope)))
            return Data("{}".utf8)
        case .removeAccount:
            try await controller.removeAccount(
                try decoder.decode(
                    RemoveAccountRequest.self, from: requiredPayload(envelope)))
            return Data("{}".utf8)
        case .setPowerMode:
            let request = try decoder.decode(
                SetPowerModeRequest.self, from: requiredPayload(envelope))
            return try encoder.encode(power.setMode(request.mode))
        case .replaceNotificationConfiguration:
            let notifications = try requiredNotifications()
            try await notifications.replaceConfiguration(
                try decoder.decode(
                    NotificationConfiguration.self,
                    from: try notificationPayload(envelope)
                ))
            return Data("{}".utf8)
        case .notificationHistory:
            let notifications = try requiredNotifications()
            let request = try decoder.decode(
                NotificationHistoryRequest.self,
                from: try notificationPayload(envelope)
            )
            guard (1...100).contains(request.limit) else {
                throw ManagementControllerError.invalidRequest
            }
            return try encoder.encode(
                await notifications.history(limit: request.limit, before: request.before))
        case .acknowledgeNotification:
            let notifications = try requiredNotifications()
            let request = try decoder.decode(
                AcknowledgeNotificationRequest.self,
                from: try notificationPayload(envelope)
            )
            try await notifications.acknowledge(
                eventID: request.eventID,
                actor: .mac,
                now: Date()
            )
            return Data("{}".utf8)
        case .pairNSPanel:
            return try encoder.encode(try await requiredNotifications().pairNSPanel())
        case .clearNSPanelToken:
            try await requiredNotifications().clearNSPanelToken()
            return Data("{}".utf8)
        case .testNotificationChannel:
            let request = try decoder.decode(
                TestNotificationChannelRequest.self,
                from: try notificationPayload(envelope)
            )
            return try encoder.encode(await requiredNotifications().testChannel(request.channel))
        }
    }

    private func requiredPayload(_ envelope: ManagementEnvelope) throws -> Data {
        guard let payload = envelope.payload else { throw ManagementControllerError.invalidRequest }
        return payload
    }

    private func notificationPayload(_ envelope: ManagementEnvelope) throws -> Data {
        let payload = try requiredPayload(envelope)
        guard payload.count <= 65_536 else { throw ManagementControllerError.invalidRequest }
        return payload
    }

    private func requiredNotifications() throws -> any NotificationServiceControlling {
        guard let notifications else { throw NotificationManagementServiceError.unavailable }
        return notifications
    }
}

enum NotificationManagementServiceError: Error, Equatable {
    case unavailable
}
