import Foundation

public struct AccountID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AIProvider: String, Codable, Sendable {
    case codex
    case claude
    case deepSeek = "deepseek"
    case cursor
}

public enum AccountStatus: String, Codable, Sendable {
    case available
    case unavailable
    case authorizationRequired = "authorization_required"
    case error
}

public enum SensorFreshness: String, Codable, Sendable {
    case fresh
    case stale
    case unavailable
}

public enum SnapshotSource: String, Codable, Sendable {
    case codexAppServer = "codex_app_server"
    case claudeStatusline = "claude_statusline"
    case deepSeekAPI = "deepseek_api"
}

public struct QuotaWindow: Codable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let usedPercent: Double
    public let remainingPercent: Double
    public let windowDurationMinutes: Int
    public let resetsAt: Date

    public init(
        id: String,
        name: String?,
        usedPercent: Double,
        windowDurationMinutes: Int,
        resetsAt: Date
    ) {
        self.id = id
        self.name = name
        self.usedPercent = usedPercent
        remainingPercent = max(0, 100 - usedPercent)
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }
}

public struct RateLimitResetCredit: Codable, Equatable, Sendable {
    public let id: String
    public let resetType: String
    public let status: String
    public let grantedAt: Date
    public let expiresAt: Date?
    public let title: String?
    public let description: String?
}

public struct RateLimitResetCredits: Codable, Equatable, Sendable {
    public let availableCount: Int
    public let credits: [RateLimitResetCredit]?
}

public struct DecimalString: Codable, Equatable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        guard Self.isValid(value) else {
            throw SensorParsingError.invalidDecimal(value)
        }
        self.value = value
    }

    private static func isValid(_ value: String) -> Bool {
        value.wholeMatch(of: /-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?/) != nil
    }
}

public struct MoneyBalance: Codable, Equatable, Sendable {
    public let currency: String
    public let total: DecimalString
    public let granted: DecimalString
    public let toppedUp: DecimalString
}

public struct AccountSnapshot: Codable, Equatable, Sendable {
    public let id: AccountID
    public let provider: AIProvider
    public let label: String
    public let plan: String?
    public let status: AccountStatus
    public let source: SnapshotSource
    public let observedAt: Date
    public let quotas: [QuotaWindow]
    public let resetCredits: RateLimitResetCredits?
    public let balances: [MoneyBalance]

    public init(
        id: AccountID,
        provider: AIProvider,
        label: String,
        plan: String? = nil,
        status: AccountStatus,
        source: SnapshotSource,
        observedAt: Date,
        quotas: [QuotaWindow] = [],
        resetCredits: RateLimitResetCredits? = nil,
        balances: [MoneyBalance] = []
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.plan = plan
        self.status = status
        self.source = source
        self.observedAt = observedAt
        self.quotas = quotas
        self.resetCredits = resetCredits
        self.balances = balances
    }

    public func freshness(at date: Date, staleAfter: TimeInterval) -> SensorFreshness {
        guard status == .available else { return .unavailable }
        return date.timeIntervalSince(observedAt) < staleAfter ? .fresh : .stale
    }
}

public struct PublicSnapshotEncoder: Sendable {
    public init() {}

    public func encode(_ snapshots: [AccountSnapshot]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshots)
    }
}

public enum SensorParsingError: Error, Equatable {
    case invalidPayload
    case invalidDecimal(String)
}
