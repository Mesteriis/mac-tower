import Foundation
import MacTowerCore
import MacTowerTransport
import OSLog

final class DaemonNetworkRuntime: @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.mactower", category: "network")
    private let storage: PrivateFileStore
    private let controller: ManagementController
    private let configuration: ServiceConfiguration
    private let mqttLedger: MQTTAdvertisementLedger
    private let snapshots = SnapshotStore()
    private var httpServer: SensorHTTPServer?
    private var mqttPublisher: HomeAssistantMQTTPublisher?
    private var mqttTask: Task<Void, Never>?
    private var collectionTask: Task<Void, Never>?

    init(root: URL, controller: ManagementController) throws {
        storage = try PrivateFileStore(root: root)
        mqttLedger = try MQTTAdvertisementLedger(storage: storage)
        self.controller = controller
        if let data = try storage.read(named: "service.json") {
            configuration = try ServiceConfiguration.decodeValidated(data)
        } else {
            configuration = try ServiceConfiguration()
        }
    }

    func start() throws {
        let restored = try loadSnapshots()
        if configuration.http.enabled {
            guard !configuration.http.allowedNetworks.isEmpty else {
                throw ServiceConfigurationError.invalidCIDR
            }
            let router = SensorHTTPRouter(
                store: snapshots,
                allowedNetworks: configuration.http.allowedNetworks,
                staleAfterSeconds: configuration.staleAfterSeconds,
                selection: configuration.publication
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
        collectionTask = Task { [weak self] in
            guard let self else { return }
            for entry in restored {
                await self.snapshots.recordSuccess(entry.snapshot, attemptedAt: entry.lastAttemptAt)
                if let failure = entry.lastFailure {
                    await self.snapshots.recordFailure(
                        accountID: entry.snapshot.id,
                        attemptedAt: entry.lastAttemptAt,
                        reason: failure
                    )
                }
            }
            await self.runCollectionLoop()
        }
    }

    func stop() async {
        collectionTask?.cancel()
        mqttTask?.cancel()
        if let publisher = mqttPublisher {
            let planner = HomeAssistantMQTTPlanner(topicPrefix: configuration.mqtt.topicPrefix)
            try? await publisher.publish([planner.availabilityPublication(online: false)])
            try? await publisher.disconnect()
        }
        mqttPublisher = nil
        mqttTask = nil
        collectionTask = nil
        try? httpServer?.stop()
        httpServer = nil
        await controller.stopAllSessions()
    }

    private func runMQTT(_ publisher: HomeAssistantMQTTPublisher) async {
        let planner = HomeAssistantMQTTPlanner(topicPrefix: configuration.mqtt.topicPrefix)
        let policy = PollPolicy(intervalSeconds: configuration.pollIntervalSeconds)
        var failures = 0

        while !Task.isCancelled {
            let (disconnects, continuation) = AsyncStream<Void>.makeStream()
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
                failures = 0
                let entries = await snapshots.all()
                let publications = try planner.reconnectPublications(
                    entries: entries,
                    now: Date(),
                    staleAfterSeconds: configuration.staleAfterSeconds,
                    selection: configuration.publication
                )
                try await publishReconciled(
                    publications,
                    entries: entries,
                    planner: planner,
                    publisher: publisher
                )
                logger.info("MQTT sensor publication enabled.")
                var iterator = disconnects.makeAsyncIterator()
                _ = await iterator.next()
            } catch {
                continuation.finish()
            }
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
                staleAfterSeconds: configuration.staleAfterSeconds,
                selection: configuration.publication
            )
            try await mqttPublisher.publish(publications)
        } catch {
            logger.error("MQTT discovery republish failed; details were omitted.")
        }
    }

    private func runCollectionLoop() async {
        let planner = HomeAssistantMQTTPlanner(topicPrefix: configuration.mqtt.topicPrefix)
        while !Task.isCancelled {
            _ = await controller.collectAll(into: snapshots)
            do {
                let entries = await snapshots.all()
                try persistSnapshots(entries)
                if let mqttPublisher {
                    let publications = try planner.snapshotPublications(
                        entries: entries,
                        now: Date(),
                        staleAfterSeconds: configuration.staleAfterSeconds,
                        includeDiscovery: true,
                        selection: configuration.publication
                    )
                    try await publishReconciled(
                        publications,
                        entries: entries,
                        planner: planner,
                        publisher: mqttPublisher
                    )
                }
            } catch {
                logger.error("Sensor state publication failed; secrets and payloads were omitted.")
            }
            do {
                try await Task.sleep(
                    for: .seconds(configuration.pollIntervalSeconds),
                    clock: .continuous
                )
            } catch {
                return
            }
        }
    }

    private func loadSnapshots() throws -> [StoredSnapshot] {
        guard let data = try storage.read(named: "snapshots.json") else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode([StoredSnapshot].self, from: data)
    }

    private func persistSnapshots(_ entries: [StoredSnapshot]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try storage.write(try encoder.encode(entries), named: "snapshots.json")
    }

    private func mqttPassword() throws -> String? {
        guard let name = configuration.mqtt.passwordSecretName,
            let data = try storage.read(named: name)
        else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func publishReconciled(
        _ currentPublications: [MQTTPublication],
        entries: [StoredSnapshot],
        planner: HomeAssistantMQTTPlanner,
        publisher: HomeAssistantMQTTPublisher
    ) async throws {
        let currentTopics = planner.advertisedTopics(
            entries: entries,
            selection: configuration.publication
        )
        let stale = await mqttLedger.stalePublications(
            planner: planner,
            currentTopics: currentTopics
        )
        try await publisher.publish(currentPublications + stale)
        try await mqttLedger.commit(currentTopics)
    }
}
