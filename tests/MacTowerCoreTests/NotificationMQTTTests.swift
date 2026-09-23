import Foundation
import Testing

@testable import MacTowerCore

@Suite("Notification MQTT contract")
struct NotificationMQTTTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let eventID = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!

    @Test("Ingress uses exactly one safe source segment and is opt-in")
    func ingressParsing() throws {
        let planner = NotificationMQTTPlanner(topicPrefix: "tower/site/")
        let payload = ingressPayload()

        let parsed = try planner.parse(
            topic: "tower/site/notifications/inbox/weather",
            payload: payload,
            retained: false,
            now: now,
            configuration: configuration(ingress: true)
        )

        #expect(
            parsed
                == .ingress(
                    NotificationIngress(
                        eventID: eventID,
                        sourceID: NotificationSourceID(rawValue: "weather")!,
                        severity: .warning,
                        title: "UPS",
                        message: "Battery",
                        createdAt: now,
                        expiresAt: now.addingTimeInterval(3_600),
                        dedupKey: "ups-on-battery"
                    )))
        #expect(throws: NotificationMQTTError.ingressDisabled) {
            try planner.parse(
                topic: "tower/site/notifications/inbox/weather",
                payload: payload,
                retained: false,
                now: now,
                configuration: configuration(ingress: false)
            )
        }
    }

    @Test("Acknowledgement accepts only the exact ack topic and is opt-in")
    func acknowledgementParsing() throws {
        let planner = NotificationMQTTPlanner(topicPrefix: "tower/site")
        let payload = Data(
            #"{"event_id":"550e8400-e29b-41d4-a716-446655440000","schema_version":1}"#.utf8)

        #expect(
            try planner.parse(
                topic: "tower/site/notifications/ack",
                payload: payload,
                retained: false,
                now: now,
                configuration: configuration(acknowledgement: true)
            ) == .acknowledgement(NotificationAcknowledgement(eventID: eventID)))
        #expect(throws: NotificationMQTTError.acknowledgementDisabled) {
            try planner.parse(
                topic: "tower/site/notifications/ack",
                payload: payload,
                retained: false,
                now: now,
                configuration: configuration()
            )
        }
    }

    @Test("Retained writes are rejected before payload decoding")
    func retainedRefusalPrecedesDecoding() {
        let planner = NotificationMQTTPlanner(topicPrefix: "tower/site")

        #expect(throws: NotificationMQTTError.retainedMessage) {
            try planner.parse(
                topic: "tower/site/notifications/inbox/weather",
                payload: Data("not-json".utf8),
                retained: true,
                now: now,
                configuration: configuration(ingress: true)
            )
        }
        #expect(throws: NotificationMQTTError.retainedMessage) {
            try planner.parse(
                topic: "tower/site/notifications/ack",
                payload: Data("not-json".utf8),
                retained: true,
                now: now,
                configuration: configuration(acknowledgement: true)
            )
        }
    }

    @Test("Malformed and outbound topics never enter the parser")
    func malformedTopics() {
        let planner = NotificationMQTTPlanner(topicPrefix: "tower/site")
        let configuration = configuration(ingress: true, acknowledgement: true)
        let invalidTopics = [
            "tower/site/notifications/inbox",
            "tower/site/notifications/inbox/a/b",
            "tower/site/notifications/inbox/+",
            "tower/site/notifications/inbox/a#",
            "tower/site/notifications/ack/extra",
            "tower/site/notifications/events",
            "tower/site/notifications/panel",
            "other/notifications/inbox/weather",
            String(repeating: "x", count: NotificationMQTTPlanner.maximumTopicBytes + 1),
        ]

        for topic in invalidTopics {
            #expect(throws: NotificationMQTTError.invalidTopic) {
                try planner.parse(
                    topic: topic,
                    payload: ingressPayload(),
                    retained: false,
                    now: now,
                    configuration: configuration
                )
            }
        }
    }

    @Test("Payload limits and invalid acknowledgement UUIDs are finite errors")
    func malformedPayloads() {
        let planner = NotificationMQTTPlanner(topicPrefix: "tower/site")
        let oversized = Data(repeating: 0, count: NotificationWireCodec.maximumPayloadBytes + 1)

        #expect(throws: NotificationValidationError.payloadTooLarge) {
            try planner.parse(
                topic: "tower/site/notifications/inbox/weather",
                payload: oversized,
                retained: false,
                now: now,
                configuration: configuration(ingress: true)
            )
        }
        #expect(throws: NotificationValidationError.invalidEventID) {
            try planner.parse(
                topic: "tower/site/notifications/ack",
                payload: Data(#"{"event_id":"nope","schema_version":1}"#.utf8),
                retained: false,
                now: now,
                configuration: configuration(acknowledgement: true)
            )
        }
    }

    @Test("Publications pin topics, QoS, retain flags, and sorted public fields")
    func publications() throws {
        let planner = NotificationMQTTPlanner(topicPrefix: "tower/site/")
        let record = sampleRecord(isActive: true)

        let event = try planner.eventPublication(record)
        let panel = try planner.panelPublication(record, acknowledgementEnabled: true)
        let active = try planner.activePublication(record)
        let tombstone = planner.clearActivePublication(eventID)
        let availability = planner.availabilityPublication(online: true)

        #expect(event.topic == "tower/site/notifications/events")
        #expect(event.qos == 1 && !event.retain)
        #expect(panel.topic == "tower/site/notifications/panel")
        #expect(panel.qos == 1 && !panel.retain)
        #expect(
            active.topic == "tower/site/notifications/active/\(eventID.uuidString.lowercased())")
        #expect(active.qos == 1 && active.retain)
        #expect(tombstone.topic == active.topic)
        #expect(tombstone.qos == 1 && tombstone.retain && tombstone.payload.isEmpty)
        #expect(availability.topic == "tower/site/notifications/availability")
        #expect(availability.qos == 1 && availability.retain)
        #expect(String(decoding: availability.payload, as: UTF8.self) == "online")

        let eventJSON = String(decoding: event.payload, as: UTF8.self)
        #expect(
            eventJSON
                == #"{"created_at":"2027-01-15T08:00:00Z","event_id":"550e8400-e29b-41d4-a716-446655440000","expires_at":"2027-01-15T09:00:00Z","is_active":true,"last_seen_at":"2027-01-15T08:01:00Z","message":"Battery","occurrence_count":2,"schema_version":1,"severity":"critical","source_id":"weather","title":"UPS"}"#
        )

        let panelObject = try #require(
            JSONSerialization.jsonObject(with: panel.payload) as? [String: Any])
        #expect(panelObject["acknowledgement_enabled"] as? Bool == true)
        #expect(panelObject["delivery_plan"] == nil)
        #expect(panelObject["deliveries"] == nil)
        #expect(panelObject["dedup_key"] == nil)
    }

    private func configuration(
        ingress: Bool = false,
        acknowledgement: Bool = false
    ) -> NotificationConfiguration {
        NotificationConfiguration(
            enabled: true,
            mqttIngressEnabled: ingress,
            mqttAcknowledgementEnabled: acknowledgement
        )
    }

    private func ingressPayload() -> Data {
        Data(
            #"{"created_at":"2027-01-15T08:00:00Z","dedup_key":"ups-on-battery","event_id":"550e8400-e29b-41d4-a716-446655440000","expires_at":"2027-01-15T09:00:00Z","message":"Battery","schema_version":1,"severity":"warning","title":"UPS"}"#
                .utf8)
    }

    private func sampleRecord(isActive: Bool) -> NotificationRecord {
        NotificationRecord(
            event: NotificationEvent(
                eventID: eventID,
                sourceID: NotificationSourceID(rawValue: "weather")!,
                severity: .critical,
                title: "UPS",
                message: "Battery",
                createdAt: now,
                expiresAt: now.addingTimeInterval(3_600),
                dedupKey: "private-rule-key"
            ),
            firstSeenAt: now,
            lastSeenAt: now.addingTimeInterval(60),
            occurrenceCount: 2,
            isActive: isActive,
            deliveryPlan: NotificationDeliveryPlan(
                channels: [.mqtt, .panel],
                wakePanel: true,
                panelSound: NSPanelSound(name: .alarm1, volume: 100, countdownSeconds: 0)
            ),
            deliveries: [
                .mqtt: NotificationChannelDelivery(state: .failed),
                .panel: NotificationChannelDelivery(state: .queued),
            ]
        )
    }
}
