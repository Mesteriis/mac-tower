import Foundation
@preconcurrency import MQTTNIO
import MacTowerCore
import MacTowerTransport
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
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

    @Test("Window commands use fresh sessions and never replay retained presses")
    func mqttDockerWindowCommands() async throws {
        guard let rawPort = ProcessInfo.processInfo.environment["MACTOWER_MQTT_TEST_PORT"],
            let port = Int(rawPort)
        else { return }

        let identifier = "mac-tower-window-test-\(UUID().uuidString.lowercased())"
        let prefix = "mac_tower_test/\(identifier)"
        let epoch = UUID()
        let displayID = UUID().uuidString
        let snapshot = WindowAgentSnapshot(
            generation: UUID(),
            displays: [
                WindowDisplay(
                    id: displayID, name: "Integration Display",
                    frame: WindowRect(x: 0, y: 0, width: 1280, height: 800),
                    visibleFrame: WindowRect(x: 0, y: 0, width: 1280, height: 760),
                    isPrimary: true
                )
            ],
            availability: .ready
        )
        let planner = WindowMQTTPlanner(topicPrefix: prefix, installationID: UUID())
        let commandTopic =
            "\(prefix)/window-control/\(epoch.uuidString.lowercased())/\(displayID)/move"
        let configuration = try MQTTServiceConfiguration(
            enabled: true, host: "127.0.0.1", port: port, topicPrefix: prefix)
        let sender = mqttClient(port: port, identifier: identifier + "-sender")
        _ = try await sender.v5.connect(cleanStart: true, properties: [.sessionExpiryInterval(0)])

        // Leave a persistent session with a queued QoS 1 press and a retained press.
        // A fresh MacTower connection must discard both, for different reasons.
        let previousSession = mqttClient(port: port, identifier: identifier)
        _ = try await previousSession.v5.connect(
            cleanStart: true, properties: [.sessionExpiryInterval(60)])
        _ = try await previousSession.v5.subscribe(to: [
            .init(topicFilter: commandTopic, qos: .atLeastOnce)
        ])
        try await previousSession.v5.disconnect()
        try await previousSession.shutdown()
        try await send(sender, topic: commandTopic, payload: Data("PRESS".utf8), retain: false)
        try await send(sender, topic: commandTopic, payload: Data("PRESS".utf8), retain: true)

        let events = MQTTIntegrationEvents()
        let publisher = HomeAssistantMQTTPublisher(
            configuration: configuration, password: nil, clientIdentifier: identifier)
        try await publisher.connect(
            onHomeAssistantBirth: { events.append(.birth) },
            onDisconnect: {},
            onWindowCommand: { events.append(.command($0, $1, $2)) }
        )
        try await send(sender, topic: commandTopic, payload: Data("PRESS".utf8), retain: false)
        try await events.waitForCount(1)
        #expect(events.values == [.command(commandTopic, Data("PRESS".utf8), false)])

        // Retain-as-published preserves the flag even for a live retained write.
        // The planner rejects it; it must never become a delayed movement.
        try await send(sender, topic: commandTopic, payload: Data("PRESS".utf8), retain: true)
        try await events.waitForCount(2)
        #expect(events.values.last == .command(commandTopic, Data("PRESS".utf8), true))
        #expect(
            planner.commandDisplayID(
                topic: commandTopic, payload: Data("PRESS".utf8), retained: true, epoch: epoch,
                snapshot: snapshot, enabled: true) == nil)

        try await send(
            sender, topic: commandTopic,
            payload: Data(repeating: 65, count: WindowMQTTPlanner.maximumCommandPayloadBytes + 1),
            retain: false)
        try await send(
            sender, topic: "\(prefix)/window-control/not-an-epoch/\(displayID)/move",
            payload: Data("PRESS".utf8), retain: false)
        try await send(
            sender, topic: "homeassistant/status", payload: Data("online".utf8), retain: false)
        try await events.waitForCount(3)
        #expect(
            events.values == [
                .command(commandTopic, Data("PRESS".utf8), false),
                .command(commandTopic, Data("PRESS".utf8), true),
                .birth,
            ])

        let publications = planner.publications(snapshot: snapshot, enabled: true, epoch: epoch)
        let discovery = try #require(
            publications.first { $0.topic.hasPrefix("homeassistant/button/") })
        let stateTopic = "\(prefix)/accounts/integration/state"
        let result = planner.resultPublication(
            .init(requestID: UUID(), displayID: displayID, code: .success))
        try await publisher.publish(
            publications + [
                MQTTPublication(topic: stateTopic, payload: Data(#"{"status":"ok"}"#.utf8)),
                result,
            ])
        try await publisher.disconnect()

        // No session survives a normal disconnect, even when resumption is requested.
        let sessionProbe = mqttClient(port: port, identifier: identifier)
        let acknowledgement = try await sessionProbe.v5.connect(
            cleanStart: false, properties: [.sessionExpiryInterval(0)])
        #expect(!acknowledgement.sessionPresent)
        try await sessionProbe.v5.disconnect()
        try await sessionProbe.shutdown()

        try await send(sender, topic: commandTopic, payload: Data("PRESS".utf8), retain: false)
        let reconnectEvents = MQTTIntegrationEvents()
        let reconnected = HomeAssistantMQTTPublisher(
            configuration: configuration, password: nil, clientIdentifier: identifier)
        try await reconnected.connect(
            onHomeAssistantBirth: {}, onDisconnect: {},
            onWindowCommand: { reconnectEvents.append(.command($0, $1, $2)) }
        )
        try await send(sender, topic: commandTopic, payload: Data("PRESS".utf8), retain: false)
        try await reconnectEvents.waitForCount(1)
        #expect(reconnectEvents.values == [.command(commandTopic, Data("PRESS".utf8), false)])

        // Session cleanup must not erase retained discovery/state, and result events
        // must not be retained. A fresh observer provides the wire-level proof.
        let retainedEvents = MQTTIntegrationEvents()
        sender.addPublishListener(named: "retained-observer") { response in
            guard case .success(let message) = response else { return }
            retainedEvents.append(
                .command(message.topicName, Data(message.payload.readableBytesView), message.retain)
            )
        }
        _ = try await sender.v5.subscribe(to: [
            .init(topicFilter: discovery.topic, qos: .atLeastOnce, retainHandling: .sendAlways),
            .init(topicFilter: stateTopic, qos: .atLeastOnce, retainHandling: .sendAlways),
            .init(topicFilter: result.topic, qos: .atMostOnce, retainHandling: .sendAlways),
        ])
        try await retainedEvents.waitForCount(2)
        #expect(Set(retainedEvents.values.compactMap(\.topic)) == [discovery.topic, stateTopic])
        try await reconnected.publish([result])
        try await retainedEvents.waitForCount(3)
        #expect(retainedEvents.values.last == .command(result.topic, result.payload, false))

        try await reconnected.disconnect()
        sender.removePublishListener(named: "retained-observer")
        try await sender.v5.disconnect()
        try await sender.shutdown()
    }

    private func mqttClient(port: Int, identifier: String) -> MQTTClient {
        MQTTClient(
            host: "127.0.0.1", port: port, identifier: identifier,
            eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
            configuration: .init(version: .v5_0)
        )
    }

    private func send(_ client: MQTTClient, topic: String, payload: Data, retain: Bool) async throws
    {
        var buffer = ByteBufferAllocator().buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        _ = try await client.v5.publish(
            to: topic, payload: buffer, qos: .atLeastOnce, retain: retain)
    }
}

private enum MQTTIntegrationEvent: Equatable, Sendable {
    case command(String, Data, Bool)
    case birth

    var topic: String? {
        guard case .command(let topic, _, _) = self else { return nil }
        return topic
    }
}

private final class MQTTIntegrationEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [MQTTIntegrationEvent] = []

    var values: [MQTTIntegrationEvent] { lock.withLock { recorded } }

    func append(_ event: MQTTIntegrationEvent) {
        lock.withLock { recorded.append(event) }
    }

    func waitForCount(_ count: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while values.count < count {
            guard clock.now < deadline else { throw MQTTIntegrationError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum MQTTIntegrationError: Error {
    case timeout
}
