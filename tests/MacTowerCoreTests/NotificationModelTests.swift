import Foundation
import Testing

@testable import MacTowerCore

@Suite("Notification model")
struct NotificationModelTests {
    private let now = Date(timeIntervalSince1970: 1_790_102_100)

    @Test("Valid ingress accepts fractional RFC 3339 and ignores unknown fields")
    func validIngressBecomesFiniteEvent() throws {
        let data = Data(
            #"{"schema_version":1,"event_id":"550e8400-e29b-41d4-a716-446655440000","severity":"warning","title":"UPS","message":"On battery","created_at":"2026-09-22T18:30:00.123Z","expires_at":"2026-09-22T19:30:00Z","dedup_key":"ups-on-battery","ignored":true}"#
                .utf8
        )

        let input = try NotificationWireCodec().decodeIngress(
            data,
            sourceID: "ups.main",
            now: now
        )

        #expect(input.schemaVersion == 1)
        #expect(input.eventID.uuidString.lowercased() == "550e8400-e29b-41d4-a716-446655440000")
        #expect(input.sourceID.rawValue == "ups.main")
        #expect(input.severity == .warning)
        #expect(input.title == "UPS")
        #expect(input.message == "On battery")
        #expect(input.createdAt == Date(timeIntervalSince1970: 1_790_101_800.123))
        #expect(input.expiresAt == Date(timeIntervalSince1970: 1_790_105_400))
        #expect(input.dedupKey == "ups-on-battery")
    }

    @Test("Whole-second RFC 3339 dates decode")
    func wholeSecondDateDecodes() throws {
        let input = try NotificationWireCodec().decodeIngress(
            validIngress(createdAt: "2026-09-22T18:30:00Z"),
            sourceID: "source-1",
            now: now
        )

        #expect(input.createdAt == Date(timeIntervalSince1970: 1_790_101_800))
    }

    @Test(arguments: ["bad/source", "", String(repeating: "a", count: 65), ".hidden"])
    func invalidSourceIsRejected(_ source: String) {
        #expect(throws: NotificationValidationError.self) {
            try NotificationSourceID(validating: source)
        }
    }

    @Test("RawRepresentable construction cannot bypass source validation")
    func rawSourceConstructionIsValidated() {
        #expect(NotificationSourceID(rawValue: "valid.source") != nil)
        #expect(NotificationSourceID(rawValue: "bad/source") == nil)
    }

    @Test("Source identifiers encode as validated strings")
    func sourceIDCodableUsesOneString() throws {
        let source = try NotificationSourceID(validating: "ups.main-1")
        let encoded = try JSONEncoder().encode(source)
        #expect(String(decoding: encoded, as: UTF8.self) == #""ups.main-1""#)
        #expect(try JSONDecoder().decode(NotificationSourceID.self, from: encoded) == source)
        #expect(throws: NotificationValidationError.self) {
            try JSONDecoder().decode(NotificationSourceID.self, from: Data(#""bad/source""#.utf8))
        }
    }

    @Test("Payload size is checked before JSON decoding")
    func oversizedPayloadIsRejected() {
        #expect(throws: NotificationValidationError.payloadTooLarge) {
            try NotificationWireCodec().decodeIngress(
                Data(repeating: 65, count: NotificationWireCodec.maximumPayloadBytes + 1),
                sourceID: "source",
                now: now
            )
        }
    }

    @Test(
        "Invalid finite ingress fields are rejected",
        arguments: [
            #"{"schema_version":2,"event_id":"550e8400-e29b-41d4-a716-446655440000","severity":"info","title":"x","message":"x","created_at":"2026-09-22T18:00:00Z"}"#,
            #"{"schema_version":1,"event_id":"not-a-uuid","severity":"info","title":"x","message":"x","created_at":"2026-09-22T18:00:00Z"}"#,
            #"{"schema_version":1,"event_id":"550e8400-e29b-41d4-a716-446655440000","severity":"urgent","title":"x","message":"x","created_at":"2026-09-22T18:00:00Z"}"#,
            #"{"schema_version":1,"event_id":"550e8400-e29b-41d4-a716-446655440000","severity":"info","title":"","message":"x","created_at":"2026-09-22T18:00:00Z"}"#,
            #"{"schema_version":1,"event_id":"550e8400-e29b-41d4-a716-446655440000","severity":"info","title":"x","message":"","created_at":"2026-09-22T18:00:00Z"}"#,
            #"{"schema_version":1,"event_id":"550e8400-e29b-41d4-a716-446655440000","severity":"info","title":"x","message":"x","created_at":"not-a-date"}"#,
            #"{"schema_version":1,"event_id":"550e8400-e29b-41d4-a716-446655440000","severity":"info","title":"x","message":"x","created_at":"2026-09-22T18:00:00Z","dedup_key":"bad\nkey"}"#,
        ]
    )
    func invalidFiniteFieldsAreRejected(_ json: String) {
        #expect(throws: NotificationValidationError.self) {
            try NotificationWireCodec().decodeIngress(
                Data(json.utf8),
                sourceID: "source",
                now: now
            )
        }
    }

    @Test("Text and deduplication boundaries are enforced")
    func boundedStringsAreEnforced() throws {
        let codec = NotificationWireCodec()
        let tooLongTitle = String(repeating: "x", count: 161)
        let tooLongMessage = String(repeating: "x", count: 2_001)
        let tooLongDedup = String(repeating: "x", count: 129)

        #expect(throws: NotificationValidationError.invalidTitle) {
            try codec.decodeIngress(
                validIngress(title: tooLongTitle), sourceID: "source", now: now)
        }
        #expect(throws: NotificationValidationError.invalidMessage) {
            try codec.decodeIngress(
                validIngress(message: tooLongMessage), sourceID: "source", now: now)
        }
        #expect(throws: NotificationValidationError.invalidDedupKey) {
            try codec.decodeIngress(
                validIngress(dedupKey: tooLongDedup), sourceID: "source", now: now)
        }

        let boundary = try codec.decodeIngress(
            validIngress(
                title: String(repeating: "x", count: 160),
                message: String(repeating: "y", count: 2_000),
                dedupKey: String(repeating: "z", count: 128)
            ),
            sourceID: "source",
            now: now
        )
        #expect(boundary.title.unicodeScalars.count == 160)
        #expect(boundary.message.unicodeScalars.count == 2_000)
    }

    @Test("Expired, inconsistent, and far-future dates are rejected")
    func temporalBoundariesAreEnforced() {
        let codec = NotificationWireCodec()
        #expect(throws: NotificationValidationError.expired) {
            try codec.decodeIngress(
                validIngress(
                    createdAt: "2026-09-22T18:00:00Z",
                    expiresAt: "2026-09-22T18:01:00Z"
                ),
                sourceID: "source",
                now: now
            )
        }
        #expect(throws: NotificationValidationError.invalidExpiry) {
            try codec.decodeIngress(
                validIngress(
                    createdAt: "2026-09-22T18:30:00Z",
                    expiresAt: "2026-09-22T18:29:59Z"
                ),
                sourceID: "source",
                now: Date(timeIntervalSince1970: 1_790_101_700)
            )
        }
        #expect(throws: NotificationValidationError.futureEvent) {
            try codec.decodeIngress(
                validIngress(createdAt: "2026-09-22T18:40:01Z"),
                sourceID: "source",
                now: now
            )
        }
    }

    @Test("Acknowledgements accept only schema one and a UUID")
    func acknowledgementIsFinite() throws {
        let codec = NotificationWireCodec()
        let acknowledgement = try codec.decodeAcknowledgement(
            Data(
                #"{"schema_version":1,"event_id":"550e8400-e29b-41d4-a716-446655440000","ignored":true}"#
                    .utf8
            )
        )
        #expect(acknowledgement.schemaVersion == 1)
        #expect(
            acknowledgement.eventID
                == UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))

        for invalid in [
            #"{"schema_version":2,"event_id":"550e8400-e29b-41d4-a716-446655440000"}"#,
            #"{"schema_version":1,"event_id":"bad"}"#,
            #"{"schema_version":1}"#,
        ] {
            #expect(throws: NotificationValidationError.self) {
                try codec.decodeAcknowledgement(Data(invalid.utf8))
            }
        }
    }

    @Test("Public event encoding uses snake case and RFC 3339")
    func eventEncodingIsStable() throws {
        let input = try NotificationWireCodec().decodeIngress(
            validIngress(createdAt: "2026-09-22T18:30:00Z"),
            sourceID: "ups.main",
            now: now
        )
        let event = NotificationEvent(input)
        let encoded = try NotificationWireCodec().encodeEvent(event)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["schema_version"] as? Int == 1)
        #expect(object["event_id"] as? String == "550E8400-E29B-41D4-A716-446655440000")
        #expect(object["source_id"] as? String == "ups.main")
        #expect(object["created_at"] as? String == "2026-09-22T18:30:00Z")
        #expect(object["severity"] as? String == "info")
    }

    private func validIngress(
        createdAt: String = "2026-09-22T18:30:00Z",
        expiresAt: String? = "2026-09-22T19:30:00Z",
        title: String = "x",
        message: String = "x",
        dedupKey: String? = nil
    ) -> Data {
        var object: [String: Any] = [
            "schema_version": 1,
            "event_id": "550e8400-e29b-41d4-a716-446655440000",
            "severity": "info",
            "title": title,
            "message": message,
            "created_at": createdAt,
        ]
        object["expires_at"] = expiresAt
        object["dedup_key"] = dedupKey
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
