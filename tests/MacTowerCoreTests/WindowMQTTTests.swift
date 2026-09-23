import Foundation
import MacTowerCore
import Testing

@Suite("Window MQTT contract")
struct WindowMQTTTests {
    private let installationID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let epoch = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let displayID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"

    @Test("Discovery exposes a nonretained QoS 0 button with both availability gates")
    func windowButtonDiscovery() throws {
        let planner = WindowMQTTPlanner(topicPrefix: "tower/nested", installationID: installationID)
        let publications = planner.publications(snapshot: snapshot(), enabled: true, epoch: epoch)
        let discovery = try #require(
            publications.first { $0.topic.hasPrefix("homeassistant/button/") })
        let json = try object(discovery)

        #expect(discovery.retain)
        #expect(
            json["unique_id"] as? String
                == "mac_tower_11111111-1111-1111-1111-111111111111_window_aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        )
        #expect(
            json["command_topic"] as? String
                == "tower/nested/window-control/22222222-2222-2222-2222-222222222222/\(displayID)/move"
        )
        #expect(json["payload_press"] as? String == "PRESS")
        #expect(json["retain"] as? Bool == false)
        #expect(json["qos"] as? Int == 0)
        #expect(json["availability_mode"] as? String == "all")
        let availability = try #require(json["availability"] as? [[String: String]])
        #expect(
            Set(availability.compactMap { $0["topic"] }) == [
                "tower/nested/availability", "tower/nested/window-control/availability",
            ])
        #expect(
            publications.contains {
                $0.topic == "tower/nested/window-control/availability"
                    && $0.payload == Data("online".utf8)
            })
        #expect(json["name"] as? String == "Move active window to Studio \"Display\"")
        #expect(json["state_topic"] == nil)
    }

    @Test("Epoch changes update command topics while preserving discovery identities")
    func windowStableDiscoveryIdentity() throws {
        let planner = WindowMQTTPlanner(topicPrefix: "tower", installationID: installationID)
        let first = try #require(
            planner.publications(snapshot: snapshot(), enabled: true, epoch: epoch).first {
                $0.topic.hasPrefix("homeassistant/")
            })
        let next = try #require(
            planner.publications(snapshot: snapshot(), enabled: true, epoch: UUID()).first {
                $0.topic.hasPrefix("homeassistant/")
            })
        #expect(first.topic == next.topic)
        #expect(try object(first)["unique_id"] as? String == object(next)["unique_id"] as? String)
        #expect(
            try object(first)["command_topic"] as? String != object(next)["command_topic"]
                as? String)
        #expect(
            planner.advertisedTopics(snapshot: snapshot(), enabled: true)
                == Set([first.topic, "tower/window-control/availability"]))
    }

    @Test("Disabled and missing agents publish offline and no buttons")
    func windowUnavailableDiscovery() {
        let planner = WindowMQTTPlanner(topicPrefix: "tower", installationID: installationID)
        for publications in [
            planner.publications(snapshot: snapshot(), enabled: false, epoch: epoch),
            planner.publications(snapshot: nil, enabled: true, epoch: epoch),
        ] {
            #expect(
                publications == [
                    MQTTPublication(
                        topic: "tower/window-control/availability", payload: Data("offline".utf8))
                ])
        }
        #expect(
            planner.advertisedTopics(snapshot: snapshot(), enabled: false) == [
                "tower/window-control/availability"
            ])
        let inactive = planner.publications(
            snapshot: snapshot(availability: .sessionInactive), enabled: true, epoch: epoch)
        #expect(inactive.contains { $0.topic.hasPrefix("homeassistant/button/") })
        #expect(
            inactive.contains {
                $0.topic == "tower/window-control/availability"
                    && $0.payload == Data("offline".utf8)
            })
    }

    @Test("Only a current exact nonretained press can address a known display")
    func windowCommandValidation() {
        let planner = WindowMQTTPlanner(topicPrefix: "tower/nested", installationID: installationID)
        let topic = "tower/nested/window-control/\(epoch.uuidString.lowercased())/\(displayID)/move"
        let press = Data("PRESS".utf8)
        #expect(
            planner.commandDisplayID(
                topic: topic, payload: press, retained: false, epoch: epoch, snapshot: snapshot(),
                enabled: true) == displayID)
        #expect(
            planner.commandDisplayID(
                topic: topic, payload: press, retained: false, epoch: epoch,
                snapshot: snapshot(availability: .busy), enabled: true) == displayID)

        for badTopic in [
            topic + "/extra", topic + "/", "other/" + topic,
            topic.replacingOccurrences(
                of: epoch.uuidString.lowercased(), with: UUID().uuidString.lowercased()),
            topic.replacingOccurrences(of: displayID, with: UUID().uuidString),
            topic.replacingOccurrences(of: "/move", with: "/resize"),
            topic.replacingOccurrences(of: displayID, with: "+"),
        ] {
            #expect(
                planner.commandDisplayID(
                    topic: badTopic, payload: press, retained: false, epoch: epoch,
                    snapshot: snapshot(), enabled: true) == nil)
        }
        for payload in [
            Data(), Data("press".utf8), Data("PRESS\n".utf8), Data(" PRESS".utf8),
            Data("{\"command\":\"PRESS\"}".utf8), Data(repeating: 65, count: 65_536), Data([0xff]),
        ] {
            #expect(
                planner.commandDisplayID(
                    topic: topic, payload: payload, retained: false, epoch: epoch,
                    snapshot: snapshot(), enabled: true) == nil)
        }
        #expect(
            planner.commandDisplayID(
                topic: topic, payload: press, retained: true, epoch: epoch, snapshot: snapshot(),
                enabled: true) == nil)
        #expect(
            planner.commandDisplayID(
                topic: topic, payload: press, retained: false, epoch: epoch, snapshot: snapshot(),
                enabled: false) == nil)
        #expect(
            planner.commandDisplayID(
                topic: topic, payload: press, retained: false, epoch: epoch, snapshot: nil,
                enabled: true) == nil)
        for availability in [
            WindowControlAvailability.accessibilityRequired, .sessionInactive, .sessionStateUnknown,
            .unavailable,
        ] {
            #expect(
                planner.commandDisplayID(
                    topic: topic, payload: press, retained: false, epoch: epoch,
                    snapshot: snapshot(availability: availability), enabled: true) == nil)
        }
    }

    @Test("Invalid snapshots do not advertise or enable commands")
    func windowInvalidSnapshot() {
        let planner = WindowMQTTPlanner(topicPrefix: "tower", installationID: installationID)
        let valid = snapshot()
        let invalid = WindowAgentSnapshot(
            generation: valid.generation, displays: valid.displays + valid.displays,
            availability: .ready)
        let publications = planner.publications(snapshot: invalid, enabled: true, epoch: epoch)
        #expect(
            publications == [
                MQTTPublication(
                    topic: "tower/window-control/availability", payload: Data("offline".utf8))
            ])
        #expect(
            planner.commandDisplayID(
                topic: "tower/window-control/\(epoch.uuidString.lowercased())/\(displayID)/move",
                payload: Data("PRESS".utf8), retained: false, epoch: epoch, snapshot: invalid,
                enabled: true) == nil)
    }

    @Test("Display removal leaves only stale discovery topics for the cleanup ledger")
    func windowDisplayCleanupTopics() throws {
        let planner = WindowMQTTPlanner(topicPrefix: "tower", installationID: installationID)
        let previous = planner.advertisedTopics(snapshot: snapshot(), enabled: true)
        let empty = WindowAgentSnapshot(generation: UUID(), displays: [], availability: .ready)
        let current = planner.advertisedTopics(snapshot: empty, enabled: true)
        #expect(previous.subtracting(current).count == 1)
        #expect(
            try #require(previous.subtracting(current).first).hasPrefix("homeassistant/button/"))
        #expect(!current.contains { $0.hasSuffix("/move") || $0.hasSuffix("/result") })
    }

    @Test("Move results are correlated nonretained events without window metadata")
    func windowMoveResultEvent() throws {
        let planner = WindowMQTTPlanner(topicPrefix: "tower", installationID: installationID)
        let result = WindowMoveResult(requestID: epoch, displayID: displayID, code: .unsupported)
        let publication = planner.resultPublication(result)
        #expect(publication.topic == "tower/window-control/result")
        #expect(!publication.retain)
        #expect(publication.qos == 0)
        #expect(
            try JSONDecoder().decode(WindowMoveResult.self, from: publication.payload) == result)
        #expect(try Set(object(publication).keys) == ["requestID", "displayID", "code"])
    }

    private func snapshot(availability: WindowControlAvailability = .ready) -> WindowAgentSnapshot {
        WindowAgentSnapshot(
            generation: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            displays: [
                WindowDisplay(
                    id: displayID, name: "Studio \"Display\"",
                    frame: WindowRect(x: 0, y: 0, width: 1920, height: 1080),
                    visibleFrame: WindowRect(x: 0, y: 40, width: 1920, height: 1040),
                    isPrimary: true)
            ],
            availability: availability
        )
    }

    private func object(_ publication: MQTTPublication) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: publication.payload) as? [String: Any])
    }
}
