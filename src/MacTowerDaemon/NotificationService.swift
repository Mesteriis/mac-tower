import Foundation
import MacTowerCore
import MacTowerTransport
import OSLog

protocol NotificationMQTTPublishing: Sendable {
    func publish(_ publications: [MQTTPublication]) async throws
}

extension HomeAssistantMQTTPublisher: NotificationMQTTPublishing {}

protocol NotificationUserAgent: Sendable {
    var id: UUID { get }
    func deliver(_ request: MacNotificationDelivery) async -> NotificationDeliveryState
    func remove(eventID: UUID) async
}

protocol NotificationPanelControlling: Sendable {
    func wake(token: String) async throws
    func play(sound: NSPanelSound, token: String) async throws
}

extension NSPanelClient: NotificationPanelControlling {}

protocol NotificationStopping: Sendable {
    func stopNotifications() async
}

protocol NotificationServiceControlling: Sendable {
    func start() async throws
    func stop() async
    func setMQTTPublisher(_ publisher: (any NotificationMQTTPublishing)?) async
    func receiveMQTT(topic: String, payload: Data, retained: Bool, now: Date) async
}

actor NotificationService: NotificationServiceControlling, NotificationStopping {
    typealias PanelClientFactory =
        @Sendable (NSPanelConfiguration) -> any NotificationPanelControlling

    private struct PendingDelivery: Hashable {
        let eventID: UUID
        let channel: NotificationChannel
    }

    private let logger = Logger(subsystem: "dev.mactower", category: "notifications")
    private let engine: NotificationEngine
    private let planner: NotificationMQTTPlanner
    private let panelToken: String?
    private let panelClientFactory: PanelClientFactory
    private var mqttPublisher: (any NotificationMQTTPublishing)?
    private var userAgent: (any NotificationUserAgent)?
    private var pending: [PendingDelivery: NotificationDeliveryIntent] = [:]
    private var timerTask: Task<Void, Never>?
    private var invalidInputCount = 0

    init(root: URL) throws {
        let storage = try PrivateFileStore(root: root)
        let serviceConfiguration: ServiceConfiguration
        if let data = try storage.read(named: "service.json") {
            serviceConfiguration = try ServiceConfiguration.decodeValidated(data)
        } else {
            serviceConfiguration = try ServiceConfiguration()
        }
        let rawToken = try storage.read(named: "nspanel-token").map {
            String(decoding: $0, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        engine = try NotificationEngine(store: FileNotificationStateStore(root: root))
        planner = NotificationMQTTPlanner(topicPrefix: serviceConfiguration.mqtt.topicPrefix)
        panelToken = rawToken.flatMap { $0.isEmpty ? nil : $0 }
        panelClientFactory = { NSPanelClient.live(configuration: $0) }
    }

    init(
        store: any NotificationStateStore,
        topicPrefix: String,
        panelToken: String?,
        panelClientFactory: @escaping PanelClientFactory
    ) throws {
        engine = try NotificationEngine(store: store)
        planner = NotificationMQTTPlanner(topicPrefix: topicPrefix)
        self.panelToken = panelToken
        self.panelClientFactory = panelClientFactory
    }

    func start() async throws {
        guard timerTask == nil else { return }
        let effects = try await engine.dueEffects(now: Date(), calendar: .current)
        await execute(effects, attemptedAt: Date())
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30), clock: .continuous)
                } catch {
                    return
                }
                await self?.runDueEffects()
            }
        }
    }

    func stop() async {
        let task = timerTask
        timerTask = nil
        task?.cancel()
        _ = await task?.result
        if let mqttPublisher {
            try? await mqttPublisher.publish([planner.availabilityPublication(online: false)])
        }
    }

    func stopNotifications() async {
        await stop()
    }

    func setMQTTPublisher(_ publisher: (any NotificationMQTTPublishing)?) async {
        mqttPublisher = publisher
        guard publisher != nil else { return }
        await publishRecoveryState()
        await drainPending(channels: [.mqtt, .panel])
    }

    func registerUserAgent(_ agent: (any NotificationUserAgent)?) async {
        userAgent = agent
        guard agent != nil else { return }
        await drainPending(channels: [.mac])
    }

    func receiveMQTT(
        topic: String,
        payload: Data,
        retained: Bool,
        now: Date
    ) async {
        do {
            let configuration = await engine.configuration()
            switch try planner.parse(
                topic: topic,
                payload: payload,
                retained: retained,
                now: now,
                configuration: configuration
            ) {
            case .ingress(let ingress):
                let effects = try await engine.ingest(
                    ingress,
                    now: now,
                    calendar: .current
                )
                await execute(effects, attemptedAt: now)
            case .acknowledgement(let acknowledgement):
                try await acknowledge(
                    eventID: acknowledgement.eventID,
                    actor: .homeAssistant,
                    now: now
                )
            }
        } catch {
            invalidInputCount = min(invalidInputCount + 1, 10_000)
            logger.error("Notification MQTT input rejected with a finite validation error.")
        }
    }

    func acknowledge(
        eventID: UUID,
        actor: NotificationAcknowledgementActor,
        now: Date = Date()
    ) async throws {
        let effects = try await engine.acknowledge(eventID: eventID, actor: actor, now: now)
        await execute(effects, attemptedAt: now)
        await userAgent?.remove(eventID: eventID)
    }

    func replaceConfiguration(_ configuration: NotificationConfiguration) async throws {
        try await engine.replaceConfiguration(configuration)
    }

    func configuration() async -> NotificationConfiguration {
        await engine.configuration()
    }

    func summary() async -> NotificationSummary {
        let configuration = await engine.configuration()
        let enabled = configuration.enabled
        return NotificationSummary(
            engine: await engine.stateSummary(),
            mqtt: enabled ? (mqttPublisher == nil ? .unavailable : .available) : .disabled,
            mac: enabled ? (userAgent == nil ? .unavailable : .available) : .disabled,
            panel: !enabled || configuration.panel == nil
                ? .disabled
                : (mqttPublisher == nil ? .unavailable : .available),
            panelTokenPresent: panelToken != nil
        )
    }

    func history(
        limit: Int,
        before: NotificationHistoryCursor?
    ) async -> NotificationHistoryPage {
        await engine.history(limit: limit, before: before)
    }

    private func runDueEffects() async {
        do {
            let now = Date()
            let effects = try await engine.dueEffects(now: now, calendar: .current)
            await execute(effects, attemptedAt: now)
        } catch {
            logger.error("Notification reminder evaluation failed with details omitted.")
        }
    }

    private func execute(_ effects: [NotificationEffect], attemptedAt: Date) async {
        for effect in effects {
            if let delivery = effect.delivery {
                await execute(delivery, attemptedAt: attemptedAt)
            }
            if let change = effect.activeChange {
                await publish(change)
            }
        }
    }

    private func execute(
        _ intent: NotificationDeliveryIntent,
        attemptedAt: Date
    ) async {
        guard let record = await engine.record(eventID: intent.eventID) else { return }
        let key = PendingDelivery(eventID: intent.eventID, channel: intent.channel)
        let result: NotificationDeliveryState
        switch intent.channel {
        case .mqtt:
            guard let mqttPublisher else {
                pending[key] = intent
                await mark(intent, state: .failed, attemptedAt: attemptedAt)
                return
            }
            do {
                try await mqttPublisher.publish([planner.eventPublication(record)])
                pending.removeValue(forKey: key)
                result = .handedOff
            } catch {
                pending[key] = intent
                result = .failed
            }
        case .mac:
            guard let userAgent else {
                pending[key] = intent
                await mark(intent, state: .failed, attemptedAt: attemptedAt)
                return
            }
            result = await userAgent.deliver(
                MacNotificationDelivery(
                    eventID: record.event.eventID,
                    severity: record.event.severity,
                    title: record.event.title,
                    message: record.event.message
                ))
            if result == .handedOff {
                pending.removeValue(forKey: key)
            } else {
                pending[key] = intent
            }
        case .panel:
            guard let mqttPublisher else {
                pending[key] = intent
                await mark(intent, state: .failed, attemptedAt: attemptedAt)
                return
            }
            do {
                let acknowledgementEnabled = (await engine.configuration())
                    .mqttAcknowledgementEnabled
                try await mqttPublisher.publish([
                    planner.panelPublication(
                        record,
                        acknowledgementEnabled: acknowledgementEnabled
                    )
                ])
                pending.removeValue(forKey: key)
                result = .handedOff
            } catch {
                pending[key] = intent
                await mark(intent, state: .failed, attemptedAt: attemptedAt)
                return
            }
        }

        await mark(intent, state: result, attemptedAt: attemptedAt)
        if intent.channel == .panel, result == .handedOff {
            await executeDirectPanelOperations(intent, attemptedAt: attemptedAt)
        }
    }

    private func executeDirectPanelOperations(
        _ intent: NotificationDeliveryIntent,
        attemptedAt: Date
    ) async {
        guard let panelToken,
            let panelConfiguration = (await engine.configuration()).panel
        else { return }
        let client = panelClientFactory(panelConfiguration)

        if intent.wakePanel {
            do {
                try await client.wake(token: panelToken)
            } catch let error as NSPanelClientError
                where error == .timeout || error == .transport
            {
                try? await client.wake(token: panelToken)
            } catch {
                // Wake failure is isolated from the one-shot sound operation.
            }
        }

        if let sound = intent.panelSound {
            do {
                let shouldPlay = try await engine.markPanelSoundAttempted(
                    eventID: intent.eventID,
                    attemptedAt: attemptedAt
                )
                if shouldPlay {
                    try await client.play(sound: sound, token: panelToken)
                }
            } catch {
                // Sound is intentionally at-most-once after its durable attempted marker.
            }
        }
    }

    private func mark(
        _ intent: NotificationDeliveryIntent,
        state: NotificationDeliveryState,
        attemptedAt: Date
    ) async {
        do {
            try await engine.markDelivery(
                eventID: intent.eventID,
                channel: intent.channel,
                state: state,
                attemptedAt: attemptedAt
            )
        } catch {
            logger.error("Notification delivery result could not be persisted.")
        }
    }

    private func publish(_ change: NotificationActiveChange) async {
        guard let mqttPublisher else { return }
        do {
            switch change {
            case .upsert(let record):
                try await mqttPublisher.publish([planner.activePublication(record)])
            case .clear(let eventID):
                try await mqttPublisher.publish([planner.clearActivePublication(eventID)])
            }
        } catch {
            logger.error("Notification active state publication failed.")
        }
    }

    private func publishRecoveryState() async {
        guard let mqttPublisher else { return }
        do {
            var publications = [planner.availabilityPublication(online: true)]
            for record in await engine.activeRecords() {
                publications.append(try planner.activePublication(record))
            }
            try await mqttPublisher.publish(publications)
        } catch {
            logger.error("Notification MQTT recovery publication failed.")
        }
    }

    private func drainPending(channels: Set<NotificationChannel>) async {
        let deliveries =
            pending
            .filter { channels.contains($0.key.channel) }
            .sorted {
                if $0.key.eventID != $1.key.eventID {
                    return $0.key.eventID.uuidString < $1.key.eventID.uuidString
                }
                return $0.key.channel.rawValue < $1.key.channel.rawValue
            }
            .map(\.value)
        for delivery in deliveries {
            await execute(delivery, attemptedAt: Date())
        }
    }
}
