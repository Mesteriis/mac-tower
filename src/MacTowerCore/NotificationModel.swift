import Foundation

public enum NotificationValidationError: Error, Equatable, Sendable {
    case payloadTooLarge
    case invalidSourceID
    case unsupportedSchemaVersion
    case invalidEventID
    case invalidSeverity
    case invalidTitle
    case invalidMessage
    case invalidDedupKey
    case invalidDate
    case futureEvent
    case expired
    case invalidExpiry
    case malformedPayload
}

public struct NotificationSourceID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(validating value: String) throws {
        guard let validated = Self(rawValue: value) else {
            throw NotificationValidationError.invalidSourceID
        }
        self = validated
    }

    public init(from decoder: Decoder) throws {
        try self.init(validating: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isValid(_ value: String) -> Bool {
        value.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]{0,63}/) != nil
    }
}

public enum NotificationSeverity: String, Codable, CaseIterable, Sendable {
    case info
    case warning
    case critical
}

public enum NotificationChannel: String, Codable, CaseIterable, Hashable, Sendable {
    case mqtt
    case mac
    case panel
}

public enum NotificationDeliveryState: String, Codable, CaseIterable, Sendable {
    case suppressed
    case queued
    case handedOff = "handed_off"
    case failed
}

public enum NSPanelSoundName: String, Codable, CaseIterable, Sendable {
    case alert1
    case alert2
    case alert3
    case alert4
    case alert5
    case doorbell1
    case doorbell2
    case doorbell3
    case doorbell4
    case doorbell5
    case alarm1
    case alarm2
    case alarm3
    case alarm4
    case alarm5
}

public struct NSPanelSound: Codable, Equatable, Sendable {
    public let name: NSPanelSoundName
    public let volume: Int
    public let countdownSeconds: Int

    public init(name: NSPanelSoundName, volume: Int, countdownSeconds: Int) {
        self.name = name
        self.volume = volume
        self.countdownSeconds = countdownSeconds
    }
}

public struct NotificationIngress: Equatable, Sendable {
    public let schemaVersion: Int
    public let eventID: UUID
    public let sourceID: NotificationSourceID
    public let severity: NotificationSeverity
    public let title: String
    public let message: String
    public let createdAt: Date
    public let expiresAt: Date?
    public let dedupKey: String?

    public init(
        schemaVersion: Int = 1,
        eventID: UUID,
        sourceID: NotificationSourceID,
        severity: NotificationSeverity,
        title: String,
        message: String,
        createdAt: Date,
        expiresAt: Date? = nil,
        dedupKey: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.sourceID = sourceID
        self.severity = severity
        self.title = title
        self.message = message
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.dedupKey = dedupKey
    }
}

public struct NotificationEvent: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let eventID: UUID
    public let sourceID: NotificationSourceID
    public let severity: NotificationSeverity
    public let title: String
    public let message: String
    public let createdAt: Date
    public let expiresAt: Date?
    public let dedupKey: String?

    public init(_ ingress: NotificationIngress) {
        schemaVersion = ingress.schemaVersion
        eventID = ingress.eventID
        sourceID = ingress.sourceID
        severity = ingress.severity
        title = ingress.title
        message = ingress.message
        createdAt = ingress.createdAt
        expiresAt = ingress.expiresAt
        dedupKey = ingress.dedupKey
    }

    public init(
        schemaVersion: Int = 1,
        eventID: UUID,
        sourceID: NotificationSourceID,
        severity: NotificationSeverity,
        title: String,
        message: String,
        createdAt: Date,
        expiresAt: Date? = nil,
        dedupKey: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.sourceID = sourceID
        self.severity = severity
        self.title = title
        self.message = message
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.dedupKey = dedupKey
    }
}

public struct MacNotificationDelivery: Codable, Equatable, Sendable {
    public let eventID: UUID
    public let severity: NotificationSeverity
    public let title: String
    public let message: String

    public init(eventID: UUID, severity: NotificationSeverity, title: String, message: String) {
        self.eventID = eventID
        self.severity = severity
        self.title = title
        self.message = message
    }
}

public enum NotificationAcknowledgementActor: String, Codable, Sendable {
    case mac
    case homeAssistant = "home_assistant"
}

public struct NotificationAcknowledgement: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let eventID: UUID

    public init(schemaVersion: Int = 1, eventID: UUID) {
        self.schemaVersion = schemaVersion
        self.eventID = eventID
    }
}

public struct NotificationChannelDelivery: Codable, Equatable, Sendable {
    public var state: NotificationDeliveryState
    public var lastAttemptAt: Date?

    public init(state: NotificationDeliveryState, lastAttemptAt: Date? = nil) {
        self.state = state
        self.lastAttemptAt = lastAttemptAt
    }
}

public struct NotificationDeliveryPlan: Codable, Equatable, Sendable {
    public let channels: Set<NotificationChannel>
    public let wakePanel: Bool
    public let panelSound: NSPanelSound?

    public init(
        channels: Set<NotificationChannel>,
        wakePanel: Bool = false,
        panelSound: NSPanelSound? = nil
    ) {
        self.channels = channels
        self.wakePanel = wakePanel
        self.panelSound = panelSound
    }
}

public struct NotificationRecord: Codable, Equatable, Sendable {
    public var event: NotificationEvent
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var occurrenceCount: Int
    public var isActive: Bool
    public var acknowledgedAt: Date?
    public var acknowledgedBy: NotificationAcknowledgementActor?
    public var deliveryPlan: NotificationDeliveryPlan
    public var deliveries: [NotificationChannel: NotificationChannelDelivery]
    public var panelSoundAttemptedAt: Date?

    public init(
        event: NotificationEvent,
        firstSeenAt: Date,
        lastSeenAt: Date,
        occurrenceCount: Int = 1,
        isActive: Bool,
        acknowledgedAt: Date? = nil,
        acknowledgedBy: NotificationAcknowledgementActor? = nil,
        deliveryPlan: NotificationDeliveryPlan,
        deliveries: [NotificationChannel: NotificationChannelDelivery],
        panelSoundAttemptedAt: Date? = nil
    ) {
        self.event = event
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.occurrenceCount = occurrenceCount
        self.isActive = isActive
        self.acknowledgedAt = acknowledgedAt
        self.acknowledgedBy = acknowledgedBy
        self.deliveryPlan = deliveryPlan
        self.deliveries = deliveries
        self.panelSoundAttemptedAt = panelSoundAttemptedAt
    }
}

public struct NotificationHistoryCursor: Codable, Equatable, Sendable {
    public let lastSeenAt: Date
    public let eventID: UUID

    public init(lastSeenAt: Date, eventID: UUID) {
        self.lastSeenAt = lastSeenAt
        self.eventID = eventID
    }
}

public struct NotificationHistoryPage: Codable, Equatable, Sendable {
    public let records: [NotificationRecord]
    public let nextCursor: NotificationHistoryCursor?

    public init(records: [NotificationRecord], nextCursor: NotificationHistoryCursor?) {
        self.records = records
        self.nextCursor = nextCursor
    }
}

public struct NotificationWireCodec: Sendable {
    public static let maximumPayloadBytes = 16_384
    public static let maximumFutureSkew: TimeInterval = 300
    public static let maximumTitleScalars = 160
    public static let maximumMessageScalars = 2_000
    public static let maximumDedupKeyScalars = 128

    public init() {}

    public func decodeIngress(
        _ data: Data,
        sourceID: String,
        now: Date
    ) throws -> NotificationIngress {
        try validatePayloadSize(data)
        let source = try NotificationSourceID(validating: sourceID)
        let wire: WireIngress
        do {
            wire = try JSONDecoder().decode(WireIngress.self, from: data)
        } catch {
            throw NotificationValidationError.malformedPayload
        }
        guard wire.schemaVersion == 1 else {
            throw NotificationValidationError.unsupportedSchemaVersion
        }
        guard let eventID = UUID(uuidString: wire.eventID) else {
            throw NotificationValidationError.invalidEventID
        }
        guard let severity = NotificationSeverity(rawValue: wire.severity) else {
            throw NotificationValidationError.invalidSeverity
        }
        guard Self.isValidText(wire.title, maximumScalars: Self.maximumTitleScalars) else {
            throw NotificationValidationError.invalidTitle
        }
        guard Self.isValidText(wire.message, maximumScalars: Self.maximumMessageScalars) else {
            throw NotificationValidationError.invalidMessage
        }
        if let dedupKey = wire.dedupKey,
            !Self.isValidDedupKey(dedupKey)
        {
            throw NotificationValidationError.invalidDedupKey
        }
        guard let createdAt = Self.parseRFC3339(wire.createdAt) else {
            throw NotificationValidationError.invalidDate
        }
        guard createdAt <= now.addingTimeInterval(Self.maximumFutureSkew) else {
            throw NotificationValidationError.futureEvent
        }

        let expiresAt: Date?
        if let encodedExpiry = wire.expiresAt {
            guard let decodedExpiry = Self.parseRFC3339(encodedExpiry) else {
                throw NotificationValidationError.invalidDate
            }
            guard decodedExpiry > createdAt else {
                throw NotificationValidationError.invalidExpiry
            }
            guard decodedExpiry > now else {
                throw NotificationValidationError.expired
            }
            expiresAt = decodedExpiry
        } else {
            expiresAt = nil
        }

        return NotificationIngress(
            eventID: eventID,
            sourceID: source,
            severity: severity,
            title: wire.title,
            message: wire.message,
            createdAt: createdAt,
            expiresAt: expiresAt,
            dedupKey: wire.dedupKey
        )
    }

    public func decodeAcknowledgement(_ data: Data) throws -> NotificationAcknowledgement {
        try validatePayloadSize(data)
        let wire: WireAcknowledgement
        do {
            wire = try JSONDecoder().decode(WireAcknowledgement.self, from: data)
        } catch {
            throw NotificationValidationError.malformedPayload
        }
        guard wire.schemaVersion == 1 else {
            throw NotificationValidationError.unsupportedSchemaVersion
        }
        guard let eventID = UUID(uuidString: wire.eventID) else {
            throw NotificationValidationError.invalidEventID
        }
        return NotificationAcknowledgement(eventID: eventID)
    }

    public func encodeEvent(_ event: NotificationEvent) throws -> Data {
        let formatter = Self.rfc3339Formatter(fractionalSeconds: false)
        var object: [String: Any] = [
            "schema_version": event.schemaVersion,
            "event_id": event.eventID.uuidString,
            "source_id": event.sourceID.rawValue,
            "severity": event.severity.rawValue,
            "title": event.title,
            "message": event.message,
            "created_at": formatter.string(from: event.createdAt),
        ]
        if let expiresAt = event.expiresAt {
            object["expires_at"] = formatter.string(from: expiresAt)
        }
        if let dedupKey = event.dedupKey {
            object["dedup_key"] = dedupKey
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func validatePayloadSize(_ data: Data) throws {
        guard data.count <= Self.maximumPayloadBytes else {
            throw NotificationValidationError.payloadTooLarge
        }
    }

    private static func isValidText(_ value: String, maximumScalars: Int) -> Bool {
        !value.isEmpty && value.unicodeScalars.count <= maximumScalars
    }

    private static func isValidDedupKey(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.count <= maximumDedupKeyScalars
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func parseRFC3339(_ value: String) -> Date? {
        rfc3339Formatter(fractionalSeconds: true).date(from: value)
            ?? rfc3339Formatter(fractionalSeconds: false).date(from: value)
    }

    private static func rfc3339Formatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions =
            fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}

private struct WireIngress: Decodable {
    let schemaVersion: Int
    let eventID: String
    let severity: String
    let title: String
    let message: String
    let createdAt: String
    let expiresAt: String?
    let dedupKey: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case eventID = "event_id"
        case severity
        case title
        case message
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case dedupKey = "dedup_key"
    }
}

private struct WireAcknowledgement: Decodable {
    let schemaVersion: Int
    let eventID: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case eventID = "event_id"
    }
}
