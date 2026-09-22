import Foundation

public struct WindowMQTTPlanner: Sendable {
    public static let maximumCommandPayloadBytes = 64

    private let topicPrefix: String
    private let installationID: UUID

    public init(topicPrefix: String, installationID: UUID) {
        self.topicPrefix = topicPrefix
        self.installationID = installationID
    }

    public func publications(
        snapshot: WindowAgentSnapshot?, enabled: Bool, epoch: UUID
    ) -> [MQTTPublication] {
        let snapshot = validatedSnapshot(snapshot, enabled: enabled)
        let online = snapshot.map { $0.availability.isEligible && !$0.displays.isEmpty } ?? false
        var publications = [
            MQTTPublication(
                topic: availabilityTopic, payload: Data((online ? "online" : "offline").utf8))
        ]
        guard let snapshot else { return publications }
        publications += snapshot.displays.map { display in
            MQTTPublication(
                topic: discoveryTopic(display),
                payload: encode(
                    WindowButtonDiscovery(
                        name: "Move active window to \(display.name)",
                        uniqueID: uniqueID(display),
                        commandTopic:
                            "\(topicPrefix)/window-control/\(epoch.uuidString.lowercased())/\(display.id)/move",
                        availability: [
                            .init(topic: "\(topicPrefix)/availability"),
                            .init(topic: availabilityTopic),
                        ],
                        device: .init(
                            identifiers: ["mac_tower_\(installationID.uuidString.lowercased())"],
                            name: "MacTower"
                        )
                    )
                )
            )
        }
        return publications
    }

    public func advertisedTopics(snapshot: WindowAgentSnapshot?, enabled: Bool) -> Set<String> {
        var topics: Set<String> = [availabilityTopic]
        if let snapshot = validatedSnapshot(snapshot, enabled: enabled) {
            topics.formUnion(snapshot.displays.map(discoveryTopic))
        }
        return topics
    }

    public func commandDisplayID(
        topic: String,
        payload: Data,
        retained: Bool,
        epoch: UUID,
        snapshot: WindowAgentSnapshot?,
        enabled: Bool
    ) -> String? {
        guard !retained, payload.count <= Self.maximumCommandPayloadBytes,
            payload == Data("PRESS".utf8),
            let snapshot = validatedSnapshot(snapshot, enabled: enabled),
            snapshot.availability.isEligible
        else { return nil }
        let prefix = "\(topicPrefix)/window-control/\(epoch.uuidString.lowercased())/"
        guard topic.utf8.count <= prefix.utf8.count + 41, topic.hasPrefix(prefix) else {
            return nil
        }
        let suffix = topic.dropFirst(prefix.count)
        let components = suffix.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[1] == "move" else { return nil }
        return snapshot.displays.first { $0.id == components[0] }?.id
    }

    public func resultPublication(_ result: WindowMoveResult) -> MQTTPublication {
        MQTTPublication(
            topic: "\(topicPrefix)/window-control/result",
            payload: encode(result),
            qos: 0,
            retain: false
        )
    }

    private var availabilityTopic: String { "\(topicPrefix)/window-control/availability" }

    private func uniqueID(_ display: WindowDisplay) -> String {
        "mac_tower_\(installationID.uuidString.lowercased())_window_\(display.id.lowercased())"
    }

    private func discoveryTopic(_ display: WindowDisplay) -> String {
        "homeassistant/button/\(uniqueID(display))/config"
    }

    private func validatedSnapshot(
        _ snapshot: WindowAgentSnapshot?, enabled: Bool
    ) -> WindowAgentSnapshot? {
        guard enabled, let snapshot else { return nil }
        do {
            try snapshot.validate()
            return snapshot
        } catch {
            return nil
        }
    }

    private func encode(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(value)
        } catch {
            // Both payload types contain only strings, UUIDs, integers and booleans.
            preconditionFailure("Window MQTT payload could not be encoded: \(error)")
        }
    }
}

private struct WindowButtonDiscovery: Encodable {
    struct Availability: Encodable {
        let topic: String
    }

    struct Device: Encodable {
        let identifiers: [String]
        let name: String
    }

    let name: String
    let uniqueID: String
    let commandTopic: String
    let payloadPress = "PRESS"
    let qos = 0
    let retain = false
    let availability: [Availability]
    let availabilityMode = "all"
    let device: Device

    enum CodingKeys: String, CodingKey {
        case name, qos, retain, availability, device
        case uniqueID = "unique_id"
        case commandTopic = "command_topic"
        case payloadPress = "payload_press"
        case availabilityMode = "availability_mode"
    }
}
