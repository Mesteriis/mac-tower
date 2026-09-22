import Foundation

public struct MQTTPublication: Equatable, Sendable {
    public let topic: String
    public let payload: Data
    public let qos: Int
    public let retain: Bool

    public init(topic: String, payload: Data, qos: Int = 1, retain: Bool = true) {
        self.topic = topic
        self.payload = payload
        self.qos = qos
        self.retain = retain
    }
}

public struct HomeAssistantMQTTPlanner: Sendable {
    private let topicPrefix: String
    private let discoveryPrefix: String

    public init(topicPrefix: String, discoveryPrefix: String = "homeassistant") {
        self.topicPrefix = topicPrefix
        self.discoveryPrefix = discoveryPrefix
    }

    public func snapshotPublications(
        entries: [StoredSnapshot],
        now: Date,
        staleAfterSeconds: Int,
        includeDiscovery: Bool
    ) throws -> [MQTTPublication] {
        var publications = [availabilityPublication(online: true)]
        for entry in entries {
            if includeDiscovery {
                publications.append(contentsOf: try discoveryPublications(for: entry.snapshot))
            }
            publications.append(
                try statePublication(
                    entry: entry,
                    now: now,
                    staleAfterSeconds: staleAfterSeconds
                ))
        }
        return publications
    }

    public func reconnectPublications(
        entries: [StoredSnapshot],
        now: Date,
        staleAfterSeconds: Int
    ) throws -> [MQTTPublication] {
        try snapshotPublications(
            entries: entries,
            now: now,
            staleAfterSeconds: staleAfterSeconds,
            includeDiscovery: true
        )
    }

    public func homeAssistantBirthPublications(
        entries: [StoredSnapshot],
        now: Date,
        staleAfterSeconds: Int
    ) throws -> [MQTTPublication] {
        try snapshotPublications(
            entries: entries,
            now: now,
            staleAfterSeconds: staleAfterSeconds,
            includeDiscovery: true
        ).filter { $0.topic != "\(topicPrefix)/availability" }
    }

    public func removalPublications(for snapshot: AccountSnapshot) throws -> [MQTTPublication] {
        var publications = [
            MQTTPublication(topic: stateTopic(for: snapshot.id), payload: Data())
        ]
        publications.append(
            contentsOf: metricDescriptors(for: snapshot).map {
                MQTTPublication(topic: discoveryTopic(for: $0.uniqueID), payload: Data())
            })
        return publications
    }

    public func availabilityPublication(online: Bool) -> MQTTPublication {
        MQTTPublication(
            topic: "\(topicPrefix)/availability",
            payload: Data((online ? "online" : "offline").utf8)
        )
    }

    private func statePublication(
        entry: StoredSnapshot,
        now: Date,
        staleAfterSeconds: Int
    ) throws -> MQTTPublication {
        let value = PublicSensorAccount(
            entry: entry,
            now: now,
            staleAfterSeconds: staleAfterSeconds
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return MQTTPublication(
            topic: stateTopic(for: entry.snapshot.id),
            payload: try encoder.encode(value)
        )
    }

    private func discoveryPublications(for snapshot: AccountSnapshot) throws -> [MQTTPublication] {
        try metricDescriptors(for: snapshot).map { metric in
            let payload = DiscoveryPayload(
                name: "\(snapshot.label) \(metric.name)",
                uniqueID: metric.uniqueID,
                stateTopic: stateTopic(for: snapshot.id),
                valueTemplate: metric.valueTemplate,
                unitOfMeasurement: metric.unit,
                availabilityTopic: "\(topicPrefix)/availability",
                payloadAvailable: "online",
                payloadNotAvailable: "offline",
                device: .init(
                    identifiers: ["mac_tower_\(snapshot.id.rawValue)"],
                    name: "MacTower \(snapshot.label)",
                    manufacturer: "MacTower",
                    model: snapshot.provider.rawValue
                )
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return MQTTPublication(
                topic: discoveryTopic(for: metric.uniqueID),
                payload: try encoder.encode(payload)
            )
        }
    }

    private func metricDescriptors(for snapshot: AccountSnapshot) -> [MetricDescriptor] {
        var metrics: [MetricDescriptor] = []
        for (index, quota) in snapshot.quotas.enumerated() {
            let base = identifier("quota_\(quota.id)")
            metrics.append(
                .init(
                    uniqueID: uniqueID(snapshot.id, "\(base)_used"),
                    name: "\(quota.name ?? quota.id) used",
                    valueTemplate: "{{ value_json.quotas[\(index)].usedPercent }}",
                    unit: "%"
                ))
            metrics.append(
                .init(
                    uniqueID: uniqueID(snapshot.id, "\(base)_remaining"),
                    name: "\(quota.name ?? quota.id) remaining",
                    valueTemplate: "{{ value_json.quotas[\(index)].remainingPercent }}",
                    unit: "%"
                ))
            metrics.append(
                .init(
                    uniqueID: uniqueID(snapshot.id, "\(base)_resets_at"),
                    name: "\(quota.name ?? quota.id) resets at",
                    valueTemplate: "{{ value_json.quotas[\(index)].resetsAt }}",
                    unit: nil
                ))
        }
        if snapshot.resetCredits != nil {
            metrics.append(
                .init(
                    uniqueID: uniqueID(snapshot.id, "reset_credits"),
                    name: "reset credits",
                    valueTemplate: "{{ value_json.resetCredits.availableCount }}",
                    unit: nil
                ))
        }
        for (index, balance) in snapshot.balances.enumerated() {
            let currency = identifier(balance.currency.lowercased())
            for (field, name) in [
                ("total", "total"), ("granted", "granted"), ("toppedUp", "topped up"),
            ] {
                metrics.append(
                    .init(
                        uniqueID: uniqueID(
                            snapshot.id, "balance_\(currency)_\(field.lowercased())"),
                        name: "\(balance.currency) \(name) balance",
                        valueTemplate: "{{ value_json.balances[\(index)].\(field).value }}",
                        unit: balance.currency
                    ))
            }
        }
        return metrics
    }

    private func stateTopic(for id: AccountID) -> String {
        "\(topicPrefix)/accounts/\(id.rawValue)/state"
    }

    private func discoveryTopic(for uniqueID: String) -> String {
        "\(discoveryPrefix)/sensor/\(uniqueID)/config"
    }

    private func uniqueID(_ id: AccountID, _ suffix: String) -> String {
        "mac_tower_\(id.rawValue)_\(suffix)"
    }

    private func identifier(_ value: String) -> String {
        value.map { character in
            character.isLetter || character.isNumber || character == "-" ? character : "_"
        }.reduce(into: "") { $0.append($1) }
    }
}

private struct MetricDescriptor {
    let uniqueID: String
    let name: String
    let valueTemplate: String
    let unit: String?
}

private struct DiscoveryPayload: Codable {
    struct Device: Codable {
        let identifiers: [String]
        let name: String
        let manufacturer: String
        let model: String
    }

    let name: String
    let uniqueID: String
    let stateTopic: String
    let valueTemplate: String
    let unitOfMeasurement: String?
    let availabilityTopic: String
    let payloadAvailable: String
    let payloadNotAvailable: String
    let device: Device

    enum CodingKeys: String, CodingKey {
        case name
        case uniqueID = "unique_id"
        case stateTopic = "state_topic"
        case valueTemplate = "value_template"
        case unitOfMeasurement = "unit_of_measurement"
        case availabilityTopic = "availability_topic"
        case payloadAvailable = "payload_available"
        case payloadNotAvailable = "payload_not_available"
        case device
    }
}
