import Foundation

public enum NotificationConfigurationError: Error, Equatable, Sendable {
    case invalidQuietHours
    case invalidRoute
    case invalidCooldown
    case invalidReminder
    case invalidPanelSound
    case invalidPanelHost
    case invalidPanelPort
    case invalidAIThreshold
}

public struct QuietHours: Codable, Equatable, Sendable {
    public let startMinute: Int
    public let endMinute: Int

    public init(startMinute: Int, endMinute: Int) throws {
        guard (0..<1_440).contains(startMinute), (0..<1_440).contains(endMinute),
            startMinute != endMinute
        else {
            throw NotificationConfigurationError.invalidQuietHours
        }
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return false }
        let localMinute = hour * 60 + minute
        if startMinute < endMinute {
            return (startMinute..<endMinute).contains(localMinute)
        }
        return localMinute >= startMinute || localMinute < endMinute
    }

    fileprivate func validate() throws {
        _ = try QuietHours(startMinute: startMinute, endMinute: endMinute)
    }
}

public struct NotificationRoute: Codable, Equatable, Sendable {
    public var channels: Set<NotificationChannel>
    public var wakePanel: Bool
    public var panelSound: NSPanelSound?
    public var cooldownSeconds: Int
    public var reminderSeconds: Int?
    public var bypassQuietHours: Bool

    public init(
        channels: Set<NotificationChannel>,
        wakePanel: Bool = false,
        panelSound: NSPanelSound? = nil,
        cooldownSeconds: Int = 0,
        reminderSeconds: Int? = nil,
        bypassQuietHours: Bool = false
    ) {
        self.channels = channels
        self.wakePanel = wakePanel
        self.panelSound = panelSound
        self.cooldownSeconds = cooldownSeconds
        self.reminderSeconds = reminderSeconds
        self.bypassQuietHours = bypassQuietHours
    }

    fileprivate func validate(for severity: NotificationSeverity) throws {
        guard (0...86_400).contains(cooldownSeconds) else {
            throw NotificationConfigurationError.invalidCooldown
        }
        if let reminderSeconds {
            guard severity == .critical, (60...86_400).contains(reminderSeconds) else {
                throw NotificationConfigurationError.invalidReminder
            }
        }
        guard !wakePanel || channels.contains(.panel),
            panelSound == nil || channels.contains(.panel)
        else {
            throw NotificationConfigurationError.invalidRoute
        }
        if let panelSound {
            guard (0...100).contains(panelSound.volume),
                (0...1_799).contains(panelSound.countdownSeconds)
            else {
                throw NotificationConfigurationError.invalidPanelSound
            }
        }
    }
}

public struct NotificationRule: Codable, Equatable, Sendable {
    public var deliveries: [NotificationSeverity: NotificationRoute]
    public var quietHours: QuietHours?

    public init(
        deliveries: [NotificationSeverity: NotificationRoute] = [:],
        quietHours: QuietHours? = nil
    ) {
        self.deliveries = deliveries
        self.quietHours = quietHours
    }

    public static let silent = NotificationRule()

    fileprivate func validate() throws {
        try quietHours?.validate()
        for (severity, route) in deliveries {
            try route.validate(for: severity)
        }
    }
}

public struct NSPanelConfiguration: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int = 8081) {
        self.host = host
        self.port = port
    }

    fileprivate func validate() throws {
        guard (1...65_535).contains(port) else {
            throw NotificationConfigurationError.invalidPanelPort
        }
        guard Self.isExplicitLocalHost(host) else {
            throw NotificationConfigurationError.invalidPanelHost
        }
    }

    private static func isExplicitLocalHost(_ host: String) -> Bool {
        guard host == host.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            return false
        }
        let normalized = host.lowercased()
        if normalized.hasSuffix(".local") {
            return normalized.wholeMatch(of: /[a-z0-9](?:[a-z0-9-]{0,62}\.)+local/) != nil
                && !normalized.contains("..")
        }
        return (try? IPv4CIDR("\(normalized)/32"))?.isLocalNetwork == true
    }
}

public enum NSPanelPairingStatus: String, Codable, Equatable, Sendable {
    case pressDone = "press_done"
    case paired
}

public struct AIQuotaNotificationThreshold: Codable, Equatable, Sendable {
    public var accountID: AccountID
    public var quotaID: String
    public var remainingPercent: Double

    public init(accountID: AccountID, quotaID: String, remainingPercent: Double) {
        self.accountID = accountID
        self.quotaID = quotaID
        self.remainingPercent = remainingPercent
    }
}

public struct AIBalanceNotificationThreshold: Codable, Equatable, Sendable {
    public var accountID: AccountID
    public var currency: String
    public var amount: DecimalString

    public init(accountID: AccountID, currency: String, amount: DecimalString) {
        self.accountID = accountID
        self.currency = currency
        self.amount = amount
    }
}

public struct AINotificationConfiguration: Codable, Equatable, Sendable {
    public var authorizationTransitionsEnabled: Bool
    public var quotaResetTransitionsEnabled: Bool
    public var quotaThresholds: [AIQuotaNotificationThreshold]
    public var balanceThresholds: [AIBalanceNotificationThreshold]
    public var consecutiveFailureCount: Int?

    public init(
        authorizationTransitionsEnabled: Bool = false,
        quotaResetTransitionsEnabled: Bool = false,
        quotaThresholds: [AIQuotaNotificationThreshold] = [],
        balanceThresholds: [AIBalanceNotificationThreshold] = [],
        consecutiveFailureCount: Int? = nil
    ) {
        self.authorizationTransitionsEnabled = authorizationTransitionsEnabled
        self.quotaResetTransitionsEnabled = quotaResetTransitionsEnabled
        self.quotaThresholds = quotaThresholds
        self.balanceThresholds = balanceThresholds
        self.consecutiveFailureCount = consecutiveFailureCount
    }

    public static let disabled = AINotificationConfiguration()

    fileprivate func validate() throws {
        if let consecutiveFailureCount {
            guard (1...20).contains(consecutiveFailureCount) else {
                throw NotificationConfigurationError.invalidAIThreshold
            }
        }

        var quotaIdentities = Set<String>()
        for threshold in quotaThresholds {
            guard Self.isValidAccountID(threshold.accountID),
                threshold.quotaID.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]{0,63}/) != nil,
                threshold.remainingPercent.isFinite,
                (0...100).contains(threshold.remainingPercent),
                quotaIdentities.insert(
                    "\(threshold.accountID.rawValue)\u{0}\(threshold.quotaID)"
                ).inserted
            else {
                throw NotificationConfigurationError.invalidAIThreshold
            }
        }

        var balanceIdentities = Set<String>()
        for threshold in balanceThresholds {
            let decimal = Decimal(
                string: threshold.amount.value,
                locale: Locale(identifier: "en_US_POSIX"))
            guard Self.isValidAccountID(threshold.accountID),
                threshold.currency.wholeMatch(of: /[A-Z]{3,8}/) != nil,
                let decimal,
                decimal >= 0,
                balanceIdentities.insert(
                    "\(threshold.accountID.rawValue)\u{0}\(threshold.currency)"
                ).inserted
            else {
                throw NotificationConfigurationError.invalidAIThreshold
            }
        }
    }

    private static func isValidAccountID(_ accountID: AccountID) -> Bool {
        accountID.rawValue.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]{0,63}/) != nil
    }
}

public struct NotificationConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var mqttIngressEnabled: Bool
    public var mqttAcknowledgementEnabled: Bool
    public var globalRule: NotificationRule
    public var sourceRules: [NotificationSourceID: NotificationRule]
    public var panel: NSPanelConfiguration?
    public var ai: AINotificationConfiguration

    public init(
        enabled: Bool = false,
        mqttIngressEnabled: Bool = false,
        mqttAcknowledgementEnabled: Bool = false,
        globalRule: NotificationRule = .silent,
        sourceRules: [NotificationSourceID: NotificationRule] = [:],
        panel: NSPanelConfiguration? = nil,
        ai: AINotificationConfiguration = .disabled
    ) {
        self.enabled = enabled
        self.mqttIngressEnabled = mqttIngressEnabled
        self.mqttAcknowledgementEnabled = mqttAcknowledgementEnabled
        self.globalRule = globalRule
        self.sourceRules = sourceRules
        self.panel = panel
        self.ai = ai
    }

    public static let disabled = NotificationConfiguration()

    @discardableResult
    public func validated() throws -> NotificationConfiguration {
        try globalRule.validate()
        for rule in sourceRules.values {
            try rule.validate()
        }
        try panel?.validate()
        try ai.validate()
        return self
    }
}

public enum NotificationChannelAvailability: String, Codable, Equatable, Sendable {
    case disabled
    case unavailable
    case available
}

public struct NotificationEngineSummary: Codable, Equatable, Sendable {
    public let configuration: NotificationConfiguration
    public let knownSources: Set<NotificationSourceID>
    public let activeCriticalCount: Int
    public let recentRecords: [NotificationRecord]

    public init(
        configuration: NotificationConfiguration,
        knownSources: Set<NotificationSourceID>,
        activeCriticalCount: Int,
        recentRecords: [NotificationRecord]
    ) {
        self.configuration = configuration
        self.knownSources = knownSources
        self.activeCriticalCount = activeCriticalCount
        self.recentRecords = recentRecords
    }
}

public struct NotificationSummary: Codable, Equatable, Sendable {
    public let engine: NotificationEngineSummary
    public let mqtt: NotificationChannelAvailability
    public let mac: NotificationChannelAvailability
    public let panel: NotificationChannelAvailability
    public let panelTokenPresent: Bool

    public init(
        engine: NotificationEngineSummary,
        mqtt: NotificationChannelAvailability,
        mac: NotificationChannelAvailability,
        panel: NotificationChannelAvailability,
        panelTokenPresent: Bool
    ) {
        self.engine = engine
        self.mqtt = mqtt
        self.mac = mac
        self.panel = panel
        self.panelTokenPresent = panelTokenPresent
    }
}
