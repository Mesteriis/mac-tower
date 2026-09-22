import Foundation
import MacTowerCore
import MacTowerTransport
import OSLog

/// A separate advertisement ledger keeps control cleanup from touching AI sensors.
actor WindowMQTTRuntime {
    private let router: WindowCommandRouter
    private let publisher: HomeAssistantMQTTPublisher
    private let planner: WindowMQTTPlanner
    private let cleanupPlanner: HomeAssistantMQTTPlanner
    private let ledger: MQTTAdvertisementLedger
    private let logger = Logger(subsystem: "dev.mactower", category: "window-mqtt")
    private var task: Task<Void, Never>?
    private var connected = false
    private var connectionGeneration = UUID()
    private var needsPublish = true
    private var lastState: WindowRoutingState?

    init(
        service: WindowControlService, publisher: HomeAssistantMQTTPublisher,
        storage: PrivateFileStore, topicPrefix: String
    ) throws {
        router = service.router
        self.publisher = publisher
        planner = WindowMQTTPlanner(
            topicPrefix: topicPrefix, installationID: service.installationID)
        cleanupPlanner = HomeAssistantMQTTPlanner(topicPrefix: topicPrefix)
        ledger = try MQTTAdvertisementLedger(
            storage: storage, fileName: "mqtt-window-advertised-topics.json")
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.publishIfChanged()
                do { try await Task.sleep(for: .seconds(1), clock: .continuous) } catch { return }
            }
        }
    }

    func setConnected(_ value: Bool) async {
        if value != connected { connectionGeneration = UUID() }
        connected = value
        needsPublish = true
        lastState = nil
        await router.setBrokerConnected(value)
    }

    func homeAssistantStarted() { needsPublish = true }

    func receive(topic: String, payload: Data, retained: Bool) async {
        guard connected else { return }
        let generation = connectionGeneration
        let state = await router.state()
        guard
            let displayID = planner.commandDisplayID(
                topic: topic, payload: payload, retained: retained,
                epoch: state.epoch, snapshot: state.snapshot, enabled: state.enabled
            ), let result = await router.move(displayID: displayID, epoch: state.epoch)
        else { return }
        guard connected, generation == connectionGeneration else { return }
        do { try await publisher.publish([planner.resultPublication(result)]) } catch {
            logger.error("Window command result publication failed.")
        }
    }

    func stop() async {
        task?.cancel()
        task = nil
        await router.setBrokerConnected(false)
        if connected {
            do {
                try await publisher.publish(
                    planner.publications(snapshot: nil, enabled: false, epoch: UUID()))
            } catch { logger.error("Window availability publication failed during shutdown.") }
        }
        connected = false
    }

    private func publishIfChanged() async {
        let state = await router.state()
        guard connected, needsPublish || state != lastState else { return }
        needsPublish = false
        do {
            let topics = planner.advertisedTopics(snapshot: state.snapshot, enabled: state.enabled)
            let stale = await ledger.stalePublications(
                planner: cleanupPlanner, currentTopics: topics)
            let publications = planner.publications(
                snapshot: state.snapshot, enabled: state.enabled, epoch: state.epoch)
            try await publisher.publish(publications + stale)
            try await ledger.commit(topics)
            lastState = state
        } catch {
            needsPublish = true
            logger.error("Window control discovery publication failed; no payloads were logged.")
        }
    }
}
