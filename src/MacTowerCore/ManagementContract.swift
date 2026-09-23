import Foundation

public enum ManagementOperation: String, Codable, Sendable {
    case status
    case replaceConfiguration = "replace_configuration"
    case addDeepSeekAccount = "add_deepseek_account"
    case startCodexOAuth = "start_codex_oauth"
    case cancelCodexOAuth = "cancel_codex_oauth"
    case linkClaudeProfile = "link_claude_profile"
    case removeAccount = "remove_account"
    case setPowerMode = "set_power_mode"
    case replaceNotificationConfiguration = "replace_notification_configuration"
    case notificationHistory = "notification_history"
    case acknowledgeNotification = "acknowledge_notification"
    case pairNSPanel = "pair_nspanel"
    case clearNSPanelToken = "clear_nspanel_token"
    case testNotificationChannel = "test_notification_channel"
}

public enum PowerMode: String, Codable, CaseIterable, Equatable, Sendable {
    case normal
    case keepMacAwake = "keep_mac_awake"
    case keepMacAndDisplaysAwake = "keep_mac_and_displays_awake"
}

public enum PowerControlIssue: String, Codable, Equatable, Sendable {
    case invalidSettings = "invalid_settings"
    case persistenceFailed = "persistence_failed"
    case assertionCreateFailed = "assertion_create_failed"
    case assertionReleaseFailed = "assertion_release_failed"
}

public struct PowerControlStatus: Codable, Equatable, Sendable {
    public let requestedMode: PowerMode
    public let persistedMode: PowerMode?
    public let appliedMode: PowerMode
    public let issue: PowerControlIssue?

    public init(
        requestedMode: PowerMode,
        persistedMode: PowerMode?,
        appliedMode: PowerMode,
        issue: PowerControlIssue? = nil
    ) {
        self.requestedMode = requestedMode
        self.persistedMode = persistedMode
        self.appliedMode = appliedMode
        self.issue = issue
    }
}

public struct SetPowerModeRequest: Codable, Equatable, Sendable {
    public let mode: PowerMode

    public init(mode: PowerMode) {
        self.mode = mode
    }
}

public struct NotificationHistoryRequest: Codable, Equatable, Sendable {
    public let limit: Int
    public let before: NotificationHistoryCursor?

    public init(limit: Int, before: NotificationHistoryCursor? = nil) throws {
        guard (1...100).contains(limit) else {
            throw NotificationManagementRequestError.invalidHistoryLimit
        }
        self.limit = limit
        self.before = before
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            limit: container.decode(Int.self, forKey: .limit),
            before: container.decodeIfPresent(NotificationHistoryCursor.self, forKey: .before)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case limit
        case before
    }
}

public struct AcknowledgeNotificationRequest: Codable, Equatable, Sendable {
    public let eventID: UUID

    public init(eventID: UUID) {
        self.eventID = eventID
    }
}

public enum NotificationTestChannel: String, Codable, CaseIterable, Sendable {
    case mac
    case panelText = "panel_text"
    case panelWake = "panel_wake"
    case panelSound = "panel_sound"
}

public struct TestNotificationChannelRequest: Codable, Equatable, Sendable {
    public let channel: NotificationTestChannel

    public init(channel: NotificationTestChannel) {
        self.channel = channel
    }
}

public enum NotificationManagementRequestError: Error, Equatable, Sendable {
    case invalidHistoryLimit
}

public struct ManagementEnvelope: Codable, Sendable {
    public let operation: ManagementOperation
    public let payload: Data?

    public init(operation: ManagementOperation, payload: Data? = nil) {
        self.operation = operation
        self.payload = payload
    }
}

public enum AccountRegistrationError: Error, Equatable {
    case invalidID
    case invalidLabel
    case invalidPath
    case unsupportedProvider
}

public struct AccountRegistration: Codable, Equatable, Sendable {
    public let id: AccountID
    public let provider: AIProvider
    public let label: String
    public let codexHomeName: String?
    public let claudeSnapshotPath: String?
    public let deepSeekSecretName: String?

    public static func codex(id: AccountID, label: String) throws -> AccountRegistration {
        try validate(id: id, label: label)
        return AccountRegistration(
            id: id,
            provider: .codex,
            label: label,
            codexHomeName: id.rawValue,
            claudeSnapshotPath: nil,
            deepSeekSecretName: nil
        )
    }

    public static func claude(
        id: AccountID,
        label: String,
        snapshotPath: String
    ) throws -> AccountRegistration {
        try validate(id: id, label: label)
        guard snapshotPath.hasPrefix("/"),
            URL(fileURLWithPath: snapshotPath).standardizedFileURL.path == snapshotPath
        else {
            throw AccountRegistrationError.invalidPath
        }
        return AccountRegistration(
            id: id,
            provider: .claude,
            label: label,
            codexHomeName: nil,
            claudeSnapshotPath: snapshotPath,
            deepSeekSecretName: nil
        )
    }

    public static func deepSeek(id: AccountID, label: String) throws -> AccountRegistration {
        try validate(id: id, label: label)
        return AccountRegistration(
            id: id,
            provider: .deepSeek,
            label: label,
            codexHomeName: nil,
            claudeSnapshotPath: nil,
            deepSeekSecretName: "\(id.rawValue).key"
        )
    }

    public static func cursor(id: AccountID, label: String) throws -> AccountRegistration {
        throw AccountRegistrationError.unsupportedProvider
    }

    public func validate() throws {
        let expected: AccountRegistration
        switch provider {
        case .codex:
            expected = try Self.codex(id: id, label: label)
        case .claude:
            guard let claudeSnapshotPath else { throw AccountRegistrationError.invalidPath }
            expected = try Self.claude(id: id, label: label, snapshotPath: claudeSnapshotPath)
        case .deepSeek:
            expected = try Self.deepSeek(id: id, label: label)
        case .cursor:
            throw AccountRegistrationError.unsupportedProvider
        }
        guard self == expected else { throw AccountRegistrationError.invalidPath }
    }

    private static func validate(id: AccountID, label: String) throws {
        guard id.rawValue.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]{0,63}/) != nil else {
            throw AccountRegistrationError.invalidID
        }
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            label.count <= 80
        else {
            throw AccountRegistrationError.invalidLabel
        }
    }
}

public struct AddDeepSeekAccountRequest: Codable, Sendable {
    public let id: AccountID
    public let label: String
    public let apiKey: String

    public init(id: AccountID, label: String, apiKey: String) throws {
        _ = try AccountRegistration.deepSeek(id: id, label: label)
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            apiKey.count <= 4_096
        else {
            throw DeepSeekClientError.emptyAPIKey
        }
        self.id = id
        self.label = label
        self.apiKey = apiKey
    }

    public var redactedDescription: String {
        "Add DeepSeek account \(id.rawValue)"
    }
}

public struct ReplaceConfigurationRequest: Codable, Sendable {
    public let configuration: ServiceConfiguration
    public let mqttPassword: String?

    public init(configuration: ServiceConfiguration, mqttPassword: String? = nil) throws {
        self.configuration = try configuration.validateForActivation()
        guard mqttPassword.map({ $0.count <= 4_096 }) ?? true else {
            throw ManagementRequestError.invalidSecret
        }
        self.mqttPassword = mqttPassword
    }
}

public enum ManagementRequestError: Error, Equatable {
    case invalidSecret
}

public struct StartCodexOAuthRequest: Codable, Sendable {
    public let id: AccountID
    public let label: String

    public init(id: AccountID, label: String) throws {
        _ = try AccountRegistration.codex(id: id, label: label)
        self.id = id
        self.label = label
    }
}

public struct LinkClaudeProfileRequest: Codable, Sendable {
    public let id: AccountID
    public let label: String
    public let snapshotPath: String

    public init(id: AccountID, label: String, snapshotPath: String) throws {
        _ = try AccountRegistration.claude(id: id, label: label, snapshotPath: snapshotPath)
        self.id = id
        self.label = label
        self.snapshotPath = snapshotPath
    }
}

public struct RemoveAccountRequest: Codable, Sendable {
    public let id: AccountID

    public init(id: AccountID) {
        self.id = id
    }
}

public struct CancelCodexOAuthRequest: Codable, Sendable {
    public let id: AccountID

    public init(id: AccountID) {
        self.id = id
    }
}

public struct CodexOAuthStart: Codable, Sendable {
    public let loginID: String
    public let authorizationURL: URL

    public init(loginID: String, authorizationURL: URL) {
        self.loginID = loginID
        self.authorizationURL = authorizationURL
    }
}

public struct DaemonStatus: Codable, Sendable {
    public let running: Bool
    public let httpEnabled: Bool
    public let mqttEnabled: Bool
    public let configuration: ServiceConfiguration
    public let accounts: [AccountRegistration]
    public let activeCodexOAuthAccountID: AccountID?
    public let powerControl: PowerControlStatus?
    public let notificationSummary: NotificationSummary?

    public init(
        running: Bool,
        httpEnabled: Bool,
        mqttEnabled: Bool,
        configuration: ServiceConfiguration,
        accounts: [AccountRegistration],
        activeCodexOAuthAccountID: AccountID? = nil,
        powerControl: PowerControlStatus? = nil,
        notificationSummary: NotificationSummary? = nil
    ) {
        self.running = running
        self.httpEnabled = httpEnabled
        self.mqttEnabled = mqttEnabled
        self.configuration = configuration
        self.accounts = accounts
        self.activeCodexOAuthAccountID = activeCodexOAuthAccountID
        self.powerControl = powerControl
        self.notificationSummary = notificationSummary
    }
}

public struct TrustManifest: Codable, Sendable {
    public let ownerUID: UInt32
    public let appCDHash: String
    public let daemonCDHash: String

    public init(ownerUID: UInt32, appCDHash: String, daemonCDHash: String) {
        self.ownerUID = ownerUID
        self.appCDHash = appCDHash
        self.daemonCDHash = daemonCDHash
    }

    public func appRequirement() throws -> String {
        try requirement(for: appCDHash)
    }

    public func daemonRequirement() throws -> String {
        try requirement(for: daemonCDHash)
    }

    private func requirement(for hash: String) throws -> String {
        guard hash.wholeMatch(of: /[0-9a-fA-F]{40}/) != nil else {
            throw TrustManifestError.invalidCDHash
        }
        return "cdhash H\"\(hash.lowercased())\""
    }
}

public enum TrustManifestError: Error, Equatable {
    case invalidCDHash
}

@objc public protocol MacTowerDaemonXPCProtocol {
    func perform(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data?, String?) -> Void
    )

    func updateWindowAgent(
        _ snapshot: Data,
        withReply reply: @escaping @Sendable (Data?, String?) -> Void
    )

    func setWindowControlEnabled(
        _ enabled: Bool,
        withReply reply: @escaping @Sendable (Data?, String?) -> Void
    )
}
