import Foundation
@preconcurrency import MQTTNIO
import MacTowerCore
@preconcurrency import NIOCore
@preconcurrency import NIOPosix

public actor HomeAssistantMQTTPublisher {
    private let client: MQTTClient
    private let availabilityTopic: String
    private let windowCommandPrefix: String
    private let listenerName = "mac-tower-home-assistant-birth"
    private let closeListenerName = "mac-tower-reconnect"
    private var connected = false

    public init(
        configuration: MQTTServiceConfiguration,
        password: String?,
        clientIdentifier: String
    ) {
        availabilityTopic = "\(configuration.topicPrefix)/availability"
        windowCommandPrefix = "\(configuration.topicPrefix)/window-control/"
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
        onDisconnect: @escaping @Sendable () -> Void,
        onWindowCommand: (@Sendable (String, Data, Bool) -> Void)? = nil
    ) async throws {
        guard !connected else { return }
        var offline = ByteBufferAllocator().buffer(capacity: 7)
        offline.writeString("offline")
        _ = try await client.v5.connect(
            cleanStart: true,
            properties: [.sessionExpiryInterval(0)],
            will: (
                topicName: availabilityTopic,
                payload: offline,
                qos: .atLeastOnce,
                retain: true,
                properties: .init()
            )
        )
        let windowCommandPrefix = self.windowCommandPrefix
        client.addPublishListener(named: listenerName) { result in
            guard case .success(let info) = result else { return }
            if info.topicName == "homeassistant/status" {
                var payload = info.payload
                if payload.readableBytes == 6,
                    payload.readString(length: payload.readableBytes) == "online"
                {
                    onHomeAssistantBirth()
                }
            } else if let onWindowCommand,
                info.payload.readableBytes <= WindowMQTTPlanner.maximumCommandPayloadBytes,
                info.topicName.utf8.count <= windowCommandPrefix.utf8.count + 78,
                info.topicName.hasPrefix(windowCommandPrefix)
            {
                let components = info.topicName.dropFirst(windowCommandPrefix.count)
                    .split(separator: "/", omittingEmptySubsequences: false)
                guard components.count == 3, components[2] == "move",
                    UUID(uuidString: String(components[0])) != nil,
                    UUID(uuidString: String(components[1])) != nil
                else { return }
                onWindowCommand(info.topicName, Data(info.payload.readableBytesView), info.retain)
            }
        }
        client.addCloseListener(named: closeListenerName) { [weak self] _ in
            Task { await self?.markDisconnected() }
            onDisconnect()
        }
        _ = try await client.v5.subscribe(
            to: [
                .init(topicFilter: "homeassistant/status", qos: .atLeastOnce),
                .init(
                    topicFilter: "\(windowCommandPrefix)+/+/move", qos: .atMostOnce,
                    retainAsPublished: true, retainHandling: .doNotSend
                ),
            ]
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
