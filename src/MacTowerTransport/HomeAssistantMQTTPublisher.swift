import Foundation
@preconcurrency import MQTTNIO
import MacTowerCore
@preconcurrency import NIOCore
@preconcurrency import NIOPosix

public actor HomeAssistantMQTTPublisher {
    private let client: MQTTClient
    private let availabilityTopic: String
    private let listenerName = "mac-tower-home-assistant-birth"
    private let closeListenerName = "mac-tower-reconnect"
    private var connected = false

    public init(
        configuration: MQTTServiceConfiguration,
        password: String?,
        clientIdentifier: String
    ) {
        availabilityTopic = "\(configuration.topicPrefix)/availability"
        client = MQTTClient(
            host: configuration.host,
            port: configuration.port,
            identifier: clientIdentifier,
            eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
            configuration: .init(
                version: .v5_0,
                userName: configuration.username,
                password: password,
                useSSL: configuration.useTLS
            )
        )
    }

    public func connect(
        onHomeAssistantBirth: @escaping @Sendable () -> Void,
        onDisconnect: @escaping @Sendable () -> Void
    ) async throws {
        guard !connected else { return }
        var offline = ByteBufferAllocator().buffer(capacity: 7)
        offline.writeString("offline")
        _ = try await client.v5.connect(
            cleanStart: false,
            will: (
                topicName: availabilityTopic,
                payload: offline,
                qos: .atLeastOnce,
                retain: true,
                properties: .init()
            )
        )
        client.addPublishListener(named: listenerName) { result in
            guard case .success(let info) = result,
                info.topicName == "homeassistant/status"
            else { return }
            var payload = info.payload
            if payload.readString(length: payload.readableBytes) == "online" {
                onHomeAssistantBirth()
            }
        }
        client.addCloseListener(named: closeListenerName) { [weak self] _ in
            Task { await self?.markDisconnected() }
            onDisconnect()
        }
        _ = try await client.v5.subscribe(
            to: [.init(topicFilter: "homeassistant/status", qos: .atLeastOnce)]
        )
        connected = true
    }

    public func publish(_ publications: [MQTTPublication]) async throws {
        guard connected else { throw MQTTTransportError.notConnected }
        for publication in publications {
            var buffer = ByteBufferAllocator().buffer(capacity: publication.payload.count)
            buffer.writeBytes(publication.payload)
            let qos: MQTTQoS = publication.qos == 0 ? .atMostOnce : .atLeastOnce
            _ = try await client.v5.publish(
                to: publication.topic,
                payload: buffer,
                qos: qos,
                retain: publication.retain,
                properties: [.contentType("application/json")]
            )
        }
    }

    public func disconnect() async throws {
        guard connected else { return }
        client.removePublishListener(named: listenerName)
        client.removeCloseListener(named: closeListenerName)
        try await client.v5.disconnect()
        connected = false
        try await client.shutdown()
    }

    private func markDisconnected() {
        connected = false
    }
}

public enum MQTTTransportError: Error {
    case notConnected
}
