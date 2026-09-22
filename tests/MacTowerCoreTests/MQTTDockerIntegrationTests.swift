import Foundation
import MacTowerCore
import MacTowerTransport
import Testing

@Suite("MQTT Docker integration")
struct MQTTDockerIntegrationTests {
    @Test("MQTTNIO publishes retained state to a real broker")
    func mqttDockerRoundTrip() async throws {
        guard let rawPort = ProcessInfo.processInfo.environment["MACTOWER_MQTT_TEST_PORT"],
            let port = Int(rawPort)
        else {
            return
        }

        let configuration = try MQTTServiceConfiguration(
            enabled: true,
            host: "127.0.0.1",
            port: port,
            topicPrefix: "mac_tower_test"
        )
        let publisher = HomeAssistantMQTTPublisher(
            configuration: configuration,
            password: nil,
            clientIdentifier: "mac-tower-integration-\(UUID().uuidString)"
        )
        try await publisher.connect(onHomeAssistantBirth: {}, onDisconnect: {})
        try await publisher.publish([
            MQTTPublication(
                topic: "mac_tower_test/integration/state",
                payload: Data(#"{"status":"ok"}"#.utf8)
            )
        ])
        try await publisher.disconnect()
    }
}
