import Foundation
import MacTowerCore
import MacTowerTransport
import Testing

@testable import MacTowerDaemon

@Suite("Daemon notification service")
struct NotificationServiceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let eventID = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!

    @Test("Persistence precedes delivery and channel failures do not block panel operations")
    func orderedIndependentDelivery() async throws {
        let trace = NotificationTrace()
        let store = TracingNotificationStore(state: configuredState(), trace: trace)
        let publisher = RecordingNotificationPublisher(
            trace: trace,
            failingTopicSuffixes: ["/events"]
        )
        let agent = RecordingNotificationAgent(trace: trace, result: .failed)
        let panel = RecordingNotificationPanel(trace: trace, wakeFailures: 1)
        let service = try NotificationService(
            store: store,
            topicPrefix: "tower",
            panelToken: "panel-token",
            panelClientFactory: { _ in panel }
        )
        await service.setMQTTPublisher(publisher)
        await service.registerUserAgent(agent)

        await service.receiveMQTT(
            topic: "tower/notifications/inbox/weather",
            payload: ingressPayload(),
            retained: false,
            now: now
        )

        let values = trace.values
        let firstSave = try #require(values.firstIndex(where: { $0.hasPrefix("save:") }))
        let firstPublish = try #require(values.firstIndex(of: "mqtt:tower/notifications/events"))
        let panelPublish = try #require(values.firstIndex(of: "mqtt:tower/notifications/panel"))
        let firstWake = try #require(values.firstIndex(of: "panel:wake"))
        let soundSave = try #require(values.firstIndex(of: "save:sound-attempted"))
        let sound = try #require(values.firstIndex(of: "panel:sound"))
        #expect(firstSave < firstPublish)
        #expect(panelPublish < firstWake)
        #expect(soundSave < sound)
        #expect(await panel.wakeCount == 2)
        #expect(await panel.soundCount == 1)
        #expect(await agent.deliveryCount == 1)
    }

    @Test("Failed panel text handoff prevents direct wake and sound")
    func panelHandoffGate() async throws {
        let trace = NotificationTrace()
        let panel = RecordingNotificationPanel(trace: trace)
        let service = try NotificationService(
            store: TracingNotificationStore(state: configuredState(), trace: trace),
            topicPrefix: "tower",
            panelToken: "panel-token",
            panelClientFactory: { _ in panel }
        )
        await service.setMQTTPublisher(
            RecordingNotificationPublisher(
                trace: trace,
                failingTopicSuffixes: ["/panel"]
            ))

        await service.receiveMQTT(
            topic: "tower/notifications/inbox/weather",
            payload: ingressPayload(),
            retained: false,
            now: now
        )

        #expect(await panel.wakeCount == 0)
        #expect(await panel.soundCount == 0)
    }

    @Test("Reconnect republishes availability and active state; agent registration drains work")
    func reconnectAndAgentDrain() async throws {
        let trace = NotificationTrace()
        let service = try NotificationService(
            store: TracingNotificationStore(state: configuredState(), trace: trace),
            topicPrefix: "tower",
            panelToken: nil,
            panelClientFactory: { _ in RecordingNotificationPanel(trace: trace) }
        )

        await service.receiveMQTT(
            topic: "tower/notifications/inbox/weather",
            payload: ingressPayload(),
            retained: false,
            now: now
        )
        let publisher = RecordingNotificationPublisher(trace: trace)
        await service.setMQTTPublisher(publisher)
        let agent = RecordingNotificationAgent(trace: trace, result: .handedOff)
        await service.registerUserAgent(agent)

        let topics = await publisher.topics
        #expect(topics.contains("tower/notifications/availability"))
        #expect(topics.contains("tower/notifications/active/\(eventID.uuidString.lowercased())"))
        #expect(await agent.deliveryCount == 1)
    }

    @Test("Restart recovery delivers active critical but not inactive ordinary records")
    func restartRecovery() async throws {
        let trace = NotificationTrace()
        let state = configuredState(records: [activeRecord(), inactiveRecord()])
        let service = try NotificationService(
            store: TracingNotificationStore(state: state, trace: trace),
            topicPrefix: "tower",
            panelToken: nil,
            panelClientFactory: { _ in RecordingNotificationPanel(trace: trace) }
        )
        let agent = RecordingNotificationAgent(trace: trace, result: .handedOff)
        await service.registerUserAgent(agent)

        try await service.start()
        await service.stop()

        #expect(await agent.deliveredEventIDs == [eventID])
    }

    @Test("Lifecycle stops notification reminders before network teardown")
    func lifecycleOrdering() async {
        let trace = NotificationTrace()
        let lifecycle = DaemonLifecycle(
            power: RecordingPowerStopForNotifications(trace: trace),
            network: RecordingNetworkStopForNotifications(trace: trace),
            notifications: RecordingNotificationStop(trace: trace)
        )

        await lifecycle.stop()

        #expect(trace.values == ["notifications:stop", "power:stop", "network:stop"])
    }

    @Test("Corrupt notification state is reported without an implicit rewrite")
    func corruptStateIsNotRewritten() {
        let store = CorruptNotificationStore()

        #expect(throws: NotificationStoreError.malformedState) {
            _ = try NotificationService(
                store: store,
                topicPrefix: "tower",
                panelToken: nil,
                panelClientFactory: { _ in
                    RecordingNotificationPanel(trace: NotificationTrace())
                }
            )
        }
        #expect(store.saveCount == 0)
    }

    @Test("Pairing exposes no token and reports paired only after durable storage")
    func pairingStorage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mactower-pairing-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let privateStorage = try PrivateFileStore(root: root)
        let trace = NotificationTrace()
        let panel = PairingNotificationPanel(token: "secret-panel-token")
        let service = try NotificationService(
            store: TracingNotificationStore(state: configuredState(), trace: trace),
            topicPrefix: "tower",
            panelToken: nil,
            privateStorage: privateStorage,
            panelClientFactory: { _ in panel }
        )

        #expect(try await service.pairNSPanel() == .paired)
        #expect(try privateStorage.read(named: "nspanel-token") == Data("secret-panel-token".utf8))
        #expect((await service.summary()).panelTokenPresent)
        try await service.clearNSPanelToken()
        #expect(try privateStorage.read(named: "nspanel-token") == nil)
        #expect(!(await service.summary()).panelTokenPresent)
    }

    private func configuredState(records: [NotificationRecord] = []) -> NotificationPersistentState
    {
        let route = NotificationRoute(
            channels: [.mqtt, .mac, .panel],
            wakePanel: true,
            panelSound: NSPanelSound(name: .alert1, volume: 50, countdownSeconds: 3)
        )
        return NotificationPersistentState(
            configuration: NotificationConfiguration(
                enabled: true,
                mqttIngressEnabled: true,
                mqttAcknowledgementEnabled: true,
                globalRule: NotificationRule(deliveries: [.critical: route]),
                panel: NSPanelConfiguration(host: "192.168.1.20")
            ),
            knownSources: records.isEmpty ? [] : [NotificationSourceID(rawValue: "weather")!],
            records: records
        )
    }

    private func activeRecord() -> NotificationRecord {
        NotificationRecord(
            event: NotificationEvent(
                eventID: eventID,
                sourceID: NotificationSourceID(rawValue: "weather")!,
                severity: .critical,
                title: "UPS",
                message: "Battery",
                createdAt: now
            ),
            firstSeenAt: now,
            lastSeenAt: now,
            isActive: true,
            deliveryPlan: NotificationDeliveryPlan(channels: [.mac]),
            deliveries: [.mac: NotificationChannelDelivery(state: .queued)]
        )
    }

    private func inactiveRecord() -> NotificationRecord {
        NotificationRecord(
            event: NotificationEvent(
                eventID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
                sourceID: NotificationSourceID(rawValue: "weather")!,
                severity: .warning,
                title: "Old",
                message: "Old",
                createdAt: now
            ),
            firstSeenAt: now,
            lastSeenAt: now,
            isActive: false,
            deliveryPlan: NotificationDeliveryPlan(channels: [.mac]),
            deliveries: [.mac: NotificationChannelDelivery(state: .queued)]
        )
    }

    private func ingressPayload() -> Data {
        Data(
            #"{"created_at":"2027-01-15T08:00:00Z","event_id":"550e8400-e29b-41d4-a716-446655440000","message":"Battery","schema_version":1,"severity":"critical","title":"UPS"}"#
                .utf8)
    }
}

private final class NotificationTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

private final class TracingNotificationStore: NotificationStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: NotificationPersistentState
    private let trace: NotificationTrace

    init(state: NotificationPersistentState, trace: NotificationTrace) {
        self.state = state
        self.trace = trace
    }

    func load() throws -> NotificationPersistentState { lock.withLock { state } }

    func save(_ state: NotificationPersistentState) throws {
        lock.withLock { self.state = state }
        let soundAttempted = state.records.contains { $0.panelSoundAttemptedAt != nil }
        trace.append(soundAttempted ? "save:sound-attempted" : "save:state")
    }
}

private final class CorruptNotificationStore: NotificationStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var saves = 0
    var saveCount: Int { lock.withLock { saves } }

    func load() throws -> NotificationPersistentState {
        throw NotificationStoreError.malformedState
    }

    func save(_ state: NotificationPersistentState) throws {
        lock.withLock { saves += 1 }
    }
}

private actor RecordingNotificationPublisher: NotificationMQTTPublishing {
    private let trace: NotificationTrace
    private let failingTopicSuffixes: Set<String>
    private(set) var topics: [String] = []

    init(trace: NotificationTrace, failingTopicSuffixes: Set<String> = []) {
        self.trace = trace
        self.failingTopicSuffixes = failingTopicSuffixes
    }

    func publish(_ publications: [MQTTPublication]) async throws {
        for publication in publications {
            topics.append(publication.topic)
            trace.append("mqtt:\(publication.topic)")
            if failingTopicSuffixes.contains(where: publication.topic.hasSuffix) {
                throw NotificationTestFailure.expected
            }
        }
    }
}

private actor RecordingNotificationAgent: NotificationUserAgent {
    nonisolated let id = UUID()
    private let trace: NotificationTrace
    private let result: NotificationDeliveryState
    private(set) var deliveredEventIDs: [UUID] = []
    var deliveryCount: Int { deliveredEventIDs.count }

    init(trace: NotificationTrace, result: NotificationDeliveryState) {
        self.trace = trace
        self.result = result
    }

    func deliver(_ request: MacNotificationDelivery) async -> NotificationDeliveryState {
        deliveredEventIDs.append(request.eventID)
        trace.append("mac:deliver")
        return result
    }

    func remove(eventID: UUID) async {
        trace.append("mac:remove")
    }
}

private actor RecordingNotificationPanel: NotificationPanelControlling {
    private let trace: NotificationTrace
    private var remainingWakeFailures: Int
    private(set) var wakeCount = 0
    private(set) var soundCount = 0

    init(trace: NotificationTrace, wakeFailures: Int = 0) {
        self.trace = trace
        remainingWakeFailures = wakeFailures
    }

    func pair() async throws -> NSPanelPairingResult {
        .pressDone
    }

    func wake(token: String) async throws {
        wakeCount += 1
        trace.append("panel:wake")
        if remainingWakeFailures > 0 {
            remainingWakeFailures -= 1
            throw NSPanelClientError.timeout
        }
    }

    func play(sound: NSPanelSound, token: String) async throws {
        soundCount += 1
        trace.append("panel:sound")
    }
}

private actor PairingNotificationPanel: NotificationPanelControlling {
    let token: String
    init(token: String) { self.token = token }
    func pair() async throws -> NSPanelPairingResult { .paired(token: token) }
    func wake(token: String) async throws {}
    func play(sound: NSPanelSound, token: String) async throws {}
}

private struct RecordingNotificationStop: NotificationStopping {
    let trace: NotificationTrace
    func stopNotifications() async { trace.append("notifications:stop") }
}

private struct RecordingPowerStopForNotifications: PowerStopping {
    let trace: NotificationTrace
    func stopPower() async { trace.append("power:stop") }
}

private struct RecordingNetworkStopForNotifications: NetworkStopping {
    let trace: NotificationTrace
    func stop() async { trace.append("network:stop") }
}

private enum NotificationTestFailure: Error {
    case expected
}
