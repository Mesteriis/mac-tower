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
        includeDiscovery: Bool,
        selection: PublicationSelection = .all
    ) throws -> [MQTTPublication] {
        var publications = [availabilityPublication(online: true)]
        for entry in entries where selection.includes(accountID: entry.snapshot.id) {
            if includeDiscovery {
                publications.append(
                    contentsOf: try discoveryPublications(
                        for: entry.snapshot,
                        selection: selection
                    ))
            }
            publications.append(
                try statePublication(
                    entry: entry,
                    now: now,
                    staleAfterSeconds: staleAfterSeconds,
                    selection: selection
                ))
        }
        return publications
    }

    public func reconnectPublications(
        entries: [StoredSnapshot],
        now: Date,
        staleAfterSeconds: Int,
        selection: PublicationSelection = .all
    ) throws -> [MQTTPublication] {
        try snapshotPublications(
            entries: entries,
            now: now,
            staleAfterSeconds: staleAfterSeconds,
            includeDiscovery: true,
            selection: selection
        )
    }

    public func homeAssistantBirthPublications(
        entries: [StoredSnapshot],
        now: Date,
        staleAfterSeconds: Int,
        selection: PublicationSelection = .all
    ) throws -> [MQTTPublication] {
        try snapshotPublications(
            entries: entries,
            now: now,
            staleAfterSeconds: staleAfterSeconds,
            includeDiscovery: true,
            selection: selection
        ).filter { $0.topic != "\(topicPrefix)/availability" }
    }

    public func removalPublications(
        for snapshot: AccountSnapshot,
        selection: PublicationSelection = .all
    ) throws -> [MQTTPublication] {
        var publications = [
            MQTTPublication(topic: stateTopic(for: snapshot.id), payload: Data())
        ]
        publications.append(
            contentsOf: metricDescriptors(for: snapshot, selection: selection).map {
                MQTTPublication(topic: discoveryTopic(for: $0.uniqueID), payload: Data())
            })
        return publications
    }

    public func advertisedTopics(
        entries: [StoredSnapshot],
        selection: PublicationSelection = .all
    ) -> Set<String> {
        var topics: Set<String> = []
        for entry in entries where selection.includes(accountID: entry.snapshot.id) {
            topics.insert(stateTopic(for: entry.snapshot.id))
            for metric in metricDescriptors(for: entry.snapshot, selection: selection) {
                topics.insert(discoveryTopic(for: metric.uniqueID))
            }
        }
        return topics
    }

    public func staleTopicPublications(
        previouslyAdvertised: Set<String>,
        currentlyAdvertised: Set<String>
    ) -> [MQTTPublication] {
        previouslyAdvertised.subtracting(currentlyAdvertised).sorted().map {
            MQTTPublication(topic: $0, payload: Data())
        }
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
        staleAfterSeconds: Int,
        selection: PublicationSelection
    ) throws -> MQTTPublication {
        let value = PublicSensorAccount(
            entry: entry,
            now: now,
            staleAfterSeconds: staleAfterSeconds,
            selection: selection
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return MQTTPublication(
            topic: stateTopic(for: entry.snapshot.id),
            payload: try encoder.encode(value)
        )
    }

    private func discoveryPublications(
        for snapshot: AccountSnapshot,
        selection: PublicationSelection
    ) throws -> [MQTTPublication] {
        try metricDescriptors(for: snapshot, selection: selection).map { metric in
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

    private func metricDescriptors(
        for snapshot: AccountSnapshot,
        selection: PublicationSelection
    ) -> [MetricDescriptor] {
        var metrics: [MetricDescriptor] = []
        for (index, quota) in snapshot.quotas.enumerated() {
            let base = identifier("quota_\(quota.id)")
            if selection.includes(.quotaUsed) {
                metrics.append(
                    .init(
                        uniqueID: uniqueID(snapshot.id, "\(base)_used"),
                        name: "\(quota.name ?? quota.id) used",
                        valueTemplate: "{{ value_json.quotas[\(index)].usedPercent }}",
                        unit: "%"
                    ))
            }
            if selection.includes(.quotaRemaining) {
                metrics.append(
                    .init(
                        uniqueID: uniqueID(snapshot.id, "\(base)_remaining"),
                        name: "\(quota.name ?? quota.id) remaining",
                        valueTemplate: "{{ value_json.quotas[\(index)].remainingPercent }}",
                        unit: "%"
                    ))
            }
            if selection.includes(.quotaWindowDuration) {
                metrics.append(
                    .init(
                        uniqueID: uniqueID(snapshot.id, "\(base)_window_minutes"),
                        name: "\(quota.name ?? quota.id) window",
                        valueTemplate: "{{ value_json.quotas[\(index)].windowDurationMinutes }}",
                        unit: "min"
                    ))
            }
            if selection.includes(.quotaResetsAt) {
                metrics.append(
                    .init(
                        uniqueID: uniqueID(snapshot.id, "\(base)_resets_at"),
                        name: "\(quota.name ?? quota.id) resets at",
                        valueTemplate: "{{ value_json.quotas[\(index)].resetsAt }}",
                        unit: nil
                    ))
            }
        }
        if snapshot.resetCredits != nil, selection.includes(.resetCredits) {
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
            for (field, name, publishedField) in [
                ("total", "total", PublishedSensorField.balanceTotal),
                ("granted", "granted", .balanceGranted),
                ("toppedUp", "topped up", .balanceToppedUp),
            ] {
                guard selection.includes(publishedField) else { continue }
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
