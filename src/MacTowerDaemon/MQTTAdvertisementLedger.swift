import Foundation
import MacTowerCore

actor MQTTAdvertisementLedger {
    private let storage: PrivateFileStore
    private let fileName = "mqtt-advertised-topics.json"
    private var topics: Set<String>

    init(storage: PrivateFileStore) throws {
        self.storage = storage
        if let data = try storage.read(named: fileName) {
            topics = Set(try JSONDecoder().decode([String].self, from: data))
        } else {
            topics = []
        }
    }

    func stalePublications(
        planner: HomeAssistantMQTTPlanner,
        currentTopics: Set<String>
    ) -> [MQTTPublication] {
        planner.staleTopicPublications(
            previouslyAdvertised: topics,
            currentlyAdvertised: currentTopics
        )
    }

    func commit(_ currentTopics: Set<String>) throws {
        let data = try JSONEncoder().encode(currentTopics.sorted())
        try storage.write(data, named: fileName)
        topics = currentTopics
    }
}
