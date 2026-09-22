import Foundation

public enum NotificationMQTTError: Error, Equatable, Sendable {
    case invalidTopic
    case retainedMessage
    case ingressDisabled
    case acknowledgementDisabled
}

public enum NotificationMQTTMessage: Equatable, Sendable {
    case ingress(NotificationIngress)
    case acknowledgement(NotificationAcknowledgement)
}

public struct NotificationMQTTPlanner: Sendable {
    public static let maximumTopicBytes = 512

    private let topicPrefix: String
    private let codec: NotificationWireCodec

    public init(topicPrefix: String, codec: NotificationWireCodec = NotificationWireCodec()) {
        self.topicPrefix = Self.normalizedPrefix(topicPrefix)
        self.codec = codec
    }

    public func parse(
        topic: String,
        payload: Data,
        retained: Bool,
        now: Date,
        configuration: NotificationConfiguration
    ) throws -> NotificationMQTTMessage {
        guard !retained else {
            throw NotificationMQTTError.retainedMessage
        }
        guard topic.utf8.count <= Self.maximumTopicBytes,
            !topic.contains("+"), !topic.contains("#")
        else {
            throw NotificationMQTTError.invalidTopic
        }

        let namespace = "\(topicPrefix)/notifications/"
        guard topic.hasPrefix(namespace) else {
            throw NotificationMQTTError.invalidTopic
        }
        let suffix = String(topic.dropFirst(namespace.count))

        if suffix == "ack" {
            guard configuration.enabled, configuration.mqttAcknowledgementEnabled else {
                throw NotificationMQTTError.acknowledgementDisabled
            }
            return .acknowledgement(try codec.decodeAcknowledgement(payload))
        }

        let inboxPrefix = "inbox/"
        guard suffix.hasPrefix(inboxPrefix) else {
            throw NotificationMQTTError.invalidTopic
        }
        let sourceID = String(suffix.dropFirst(inboxPrefix.count))
        guard !sourceID.contains("/"), NotificationSourceID(rawValue: sourceID) != nil else {
            throw NotificationMQTTError.invalidTopic
        }
        guard configuration.enabled, configuration.mqttIngressEnabled else {
            throw NotificationMQTTError.ingressDisabled
        }
        return .ingress(try codec.decodeIngress(payload, sourceID: sourceID, now: now))
    }

    public func eventPublication(_ record: NotificationRecord) throws -> MQTTPublication {
        try publication(
            topic: "\(topicPrefix)/notifications/events",
            record: record,
            retained: false,
            acknowledgementEnabled: nil
        )
    }

    public func panelPublication(
        _ record: NotificationRecord,
        acknowledgementEnabled: Bool
    ) throws -> MQTTPublication {
        try publication(
            topic: "\(topicPrefix)/notifications/panel",
            record: record,
            retained: false,
            acknowledgementEnabled: acknowledgementEnabled
        )
    }

    public func activePublication(_ record: NotificationRecord) throws -> MQTTPublication {
        try publication(
            topic: activeTopic(record.event.eventID),
            record: record,
            retained: true,
            acknowledgementEnabled: nil
        )
    }

    public func clearActivePublication(_ eventID: UUID) -> MQTTPublication {
        MQTTPublication(topic: activeTopic(eventID), payload: Data(), qos: 1, retain: true)
    }

    public func availabilityPublication(online: Bool) -> MQTTPublication {
        MQTTPublication(
            topic: "\(topicPrefix)/notifications/availability",
            payload: Data((online ? "online" : "offline").utf8),
            qos: 1,
            retain: true
        )
    }

    private func publication(
        topic: String,
        record: NotificationRecord,
        retained: Bool,
        acknowledgementEnabled: Bool?
    ) throws -> MQTTPublication {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        var object: [String: Any] = [
            "schema_version": record.event.schemaVersion,
            "event_id": record.event.eventID.uuidString.lowercased(),
            "source_id": record.event.sourceID.rawValue,
            "severity": record.event.severity.rawValue,
            "title": record.event.title,
            "message": record.event.message,
            "created_at": formatter.string(from: record.event.createdAt),
            "last_seen_at": formatter.string(from: record.lastSeenAt),
            "occurrence_count": record.occurrenceCount,
            "is_active": record.isActive,
        ]
        if let expiresAt = record.event.expiresAt {
            object["expires_at"] = formatter.string(from: expiresAt)
        }
        if let acknowledgementEnabled {
            object["acknowledgement_enabled"] = acknowledgementEnabled
        }

        return MQTTPublication(
            topic: topic,
            payload: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            qos: 1,
            retain: retained
        )
    }

    private func activeTopic(_ eventID: UUID) -> String {
        "\(topicPrefix)/notifications/active/\(eventID.uuidString.lowercased())"
    }

    private static func normalizedPrefix(_ prefix: String) -> String {
        var normalized = prefix
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
