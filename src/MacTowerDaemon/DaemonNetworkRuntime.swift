import Foundation
import MacTowerCore
import MacTowerTransport
import OSLog

final class DaemonNetworkRuntime: @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.mactower", category: "network")
    private let storage: PrivateFileStore
    private let configuration: ServiceConfiguration
    private let snapshots = SnapshotStore()
    private var httpServer: SensorHTTPServer?
    private var mqttPublisher: HomeAssistantMQTTPublisher?
    private var mqttTask: Task<Void, Never>?

    init(root: URL) throws {
        storage = try PrivateFileStore(root: root)
        if let data = try storage.read(named: "service.json") {
            configuration = try ServiceConfiguration.decodeValidated(data)
        } else {
            configuration = try ServiceConfiguration()
        }
    }

    func start() throws {
        try restoreSnapshots()
        if configuration.http.enabled {
            guard !configuration.http.allowedNetworks.isEmpty else {
                throw ServiceConfigurationError.invalidCIDR
            }
            let router = SensorHTTPRouter(
                store: snapshots,
                allowedNetworks: configuration.http.allowedNetworks,
                staleAfterSeconds: configuration.staleAfterSeconds
            )
            let server = SensorHTTPServer(
                router: router,
                bindAddress: configuration.http.bindAddress,
                port: configuration.http.port
            )
            try server.start()
            httpServer = server
            logger.info("HTTP sensor endpoint enabled.")
        }

        if configuration.mqtt.enabled {
            let password = try mqttPassword()
            let publisher = HomeAssistantMQTTPublisher(
                configuration: configuration.mqtt,
                password: password,
                clientIdentifier: "mac-tower-\(Host.current().localizedName ?? "mac")"
            )
            mqttPublisher = publisher
            mqttTask = Task { [weak self] in
                await self?.runMQTT(publisher)
            }
        }
    }

    func stop() async {
        mqttTask?.cancel()
        if let publisher = mqttPublisher {
            let planner = HomeAssistantMQTTPlanner(topicPrefix: configuration.mqtt.topicPrefix)
            try? await publisher.publish([planner.availabilityPublication(online: false)])
            try? await publisher.disconnect()
        }
        mqttPublisher = nil
        mqttTask = nil
        try? httpServer?.stop()
        httpServer = nil
    }

    private func runMQTT(_ publisher: HomeAssistantMQTTPublisher) async {
        let planner = HomeAssistantMQTTPlanner(topicPrefix: configuration.mqtt.topicPrefix)
        let policy = PollPolicy(intervalSeconds: configuration.pollIntervalSeconds)
        var failures = 0

        while !Task.isCancelled {
            let disconnect = AsyncStream<Void> { continuation in
                Task { [self] in
                    do {
                        try await publisher.connect(
                            onHomeAssistantBirth: { [weak self] in
                                Task { await self?.publishHomeAssistantBirth() }
                            },
                            onDisconnect: {
                                continuation.yield()
                                continuation.finish()
                            }
                        )
                        let entries = await self.snapshots.all()
                        let publications = try planner.reconnectPublications(
                            entries: entries,
                            now: Date(),
                            staleAfterSeconds: self.configuration.staleAfterSeconds
                        )
                        try await publisher.publish(publications)
                        self.logger.info("MQTT sensor publication enabled.")
                    } catch {
                        continuation.finish()
                    }
                }
            }

            var iterator = disconnect.makeAsyncIterator()
            _ = await iterator.next()
            guard !Task.isCancelled else { return }
            failures += 1
            logger.error("MQTT disconnected; retrying without logging credentials or payloads.")
            let delay = policy.delay(afterConsecutiveFailures: failures)
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
        }
    }

    private func publishHomeAssistantBirth() async {
        guard let mqttPublisher else { return }
        do {
            let entries = await snapshots.all()
            let publications = try HomeAssistantMQTTPlanner(
                topicPrefix: configuration.mqtt.topicPrefix
            ).homeAssistantBirthPublications(
                entries: entries,
                now: Date(),
                staleAfterSeconds: configuration.staleAfterSeconds
            )
            try await mqttPublisher.publish(publications)
        } catch {
            logger.error("MQTT discovery republish failed; details were omitted.")
        }
    }

    private func restoreSnapshots() throws {
        guard let data = try storage.read(named: "snapshots.json") else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let restored = try decoder.decode([StoredSnapshot].self, from: data)
        for entry in restored {
            let snapshots = snapshots
            Task {
                await snapshots.recordSuccess(entry.snapshot, attemptedAt: entry.lastAttemptAt)
                if let failure = entry.lastFailure {
                    await snapshots.recordFailure(
                        accountID: entry.snapshot.id,
                        attemptedAt: entry.lastAttemptAt,
                        reason: failure
                    )
                }
            }
        }
    }

    private func mqttPassword() throws -> String? {
        guard let name = configuration.mqtt.passwordSecretName,
            let data = try storage.read(named: name)
        else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
