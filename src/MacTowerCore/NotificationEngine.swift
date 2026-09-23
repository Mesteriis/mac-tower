import Foundation

public enum NotificationEngineError: Error, Equatable, Sendable {
    case rateLimited
    case capacityReached
    case notificationNotFound
    case notificationNotActive
    case channelNotPlanned
}

public struct NotificationDeliveryIntent: Equatable, Sendable {
    public let eventID: UUID
    public let channel: NotificationChannel
    public let wakePanel: Bool
    public let panelSound: NSPanelSound?

    public init(
        eventID: UUID,
        channel: NotificationChannel,
        wakePanel: Bool,
        panelSound: NSPanelSound?
    ) {
        self.eventID = eventID
        self.channel = channel
        self.wakePanel = wakePanel
        self.panelSound = panelSound
    }
}

public enum NotificationActiveChange: Equatable, Sendable {
    case upsert(NotificationRecord)
    case clear(UUID)
}

public struct NotificationEffect: Equatable, Sendable {
    public let delivery: NotificationDeliveryIntent?
    public let activeChange: NotificationActiveChange?

    public init(
        delivery: NotificationDeliveryIntent? = nil,
        activeChange: NotificationActiveChange? = nil
    ) {
        self.delivery = delivery
        self.activeChange = activeChange
    }
}

public struct NotificationRateLimiter: Sendable {
    public let maximumPerSource: Int
    public let maximumGlobal: Int
    public let windowSeconds: TimeInterval

    private var sourceTimestamps: [NotificationSourceID: [Date]] = [:]
    private var globalTimestamps: [Date] = []

    public init(
        maximumPerSource: Int = 30,
        maximumGlobal: Int = 300,
        windowSeconds: TimeInterval = 60
    ) {
        self.maximumPerSource = maximumPerSource
        self.maximumGlobal = maximumGlobal
        self.windowSeconds = windowSeconds
    }

    public var trackedSourceCount: Int { sourceTimestamps.count }

    public mutating func admit(sourceID: NotificationSourceID, now: Date) -> Bool {
        globalTimestamps = globalTimestamps.filter { timestamp in
            let age = now.timeIntervalSince(timestamp)
            return age >= 0 && age < windowSeconds
        }
        for key in Array(sourceTimestamps.keys) {
            let retained = sourceTimestamps[key, default: []].filter { timestamp in
                let age = now.timeIntervalSince(timestamp)
                return age >= 0 && age < windowSeconds
            }
            if retained.isEmpty {
                sourceTimestamps.removeValue(forKey: key)
            } else {
                sourceTimestamps[key] = retained
            }
        }
        var source = sourceTimestamps[sourceID, default: []].filter { timestamp in
            let age = now.timeIntervalSince(timestamp)
            return age >= 0 && age < windowSeconds
        }
        guard source.count < maximumPerSource, globalTimestamps.count < maximumGlobal else {
            sourceTimestamps[sourceID] = source
            return false
        }
        source.append(now)
        globalTimestamps.append(now)
        sourceTimestamps[sourceID] = source
        return true
    }
}

public actor NotificationEngine {
    private static let maximumRecords = 5_000
    private static let maximumKnownSources = 5_000
    private static let retentionSeconds: TimeInterval = 30 * 86_400
    private static let retrySeconds: TimeInterval = 60

    private let store: any NotificationStateStore
    private let evaluator = NotificationPolicyEvaluator()
    private var state: NotificationPersistentState
    private var rateLimiter = NotificationRateLimiter()

    public init(store: any NotificationStateStore) throws {
        self.store = store
        var restored = try store.load()
        for index in restored.records.indices
        where restored.records[index].isActive
            && restored.records[index].event.severity == .critical
        {
            for channel in restored.records[index].deliveries.keys
            where restored.records[index].deliveries[channel]?.state == .queued {
                restored.records[index].deliveries[channel]?.lastAttemptAt = nil
            }
        }
        state = restored
    }

    public func ingest(
        _ input: NotificationIngress,
        now: Date,
        calendar: Calendar
    ) throws -> [NotificationEffect] {
        if state.records.contains(where: { $0.event.eventID == input.eventID }) {
            return []
        }

        var candidateLimiter = rateLimiter
        guard candidateLimiter.admit(sourceID: input.sourceID, now: now) else {
            throw NotificationEngineError.rateLimited
        }

        var candidate = state
        var effects = expireAndPrune(&candidate, now: now)
        if let dedupKey = input.dedupKey,
            let index = newestRecordIndex(
                sourceID: input.sourceID, dedupKey: dedupKey, records: candidate.records)
        {
            effects += updateDeduplicatedRecord(
                at: index,
                input: input,
                state: &candidate,
                now: now,
                calendar: calendar
            )
        } else {
            try makeRoomForNewRecord(&candidate)
            let decision = evaluator.evaluate(
                NotificationEvent(input),
                configuration: candidate.configuration,
                now: now,
                calendar: calendar
            )
            let record = makeRecord(input: input, decision: decision, now: now)
            candidate.knownSources.insert(input.sourceID)
            candidate.records.append(record)
            effects += effectsForNewDelivery(record)
        }
        pruneKnownSources(&candidate)

        try store.save(candidate)
        state = candidate
        rateLimiter = candidateLimiter
        return effects
    }

    public func acknowledge(
        eventID: UUID,
        actor: NotificationAcknowledgementActor,
        now: Date
    ) throws -> [NotificationEffect] {
        guard let index = state.records.firstIndex(where: { $0.event.eventID == eventID }) else {
            throw NotificationEngineError.notificationNotFound
        }
        if state.records[index].acknowledgedAt != nil { return [] }
        guard state.records[index].isActive,
            state.records[index].event.severity == .critical
        else {
            throw NotificationEngineError.notificationNotActive
        }

        var candidate = state
        candidate.records[index].isActive = false
        candidate.records[index].acknowledgedAt = now
        candidate.records[index].acknowledgedBy = actor
        try store.save(candidate)
        state = candidate
        return [NotificationEffect(activeChange: .clear(eventID))]
    }

    public func dueEffects(now: Date, calendar: Calendar) throws -> [NotificationEffect] {
        var candidate = state
        var effects: [NotificationEffect] = []
        var changed = false

        for index in candidate.records.indices {
            if candidate.records[index].isActive,
                let expiresAt = candidate.records[index].event.expiresAt,
                expiresAt <= now
            {
                candidate.records[index].isActive = false
                effects.append(
                    NotificationEffect(
                        activeChange: .clear(candidate.records[index].event.eventID)))
                changed = true
                continue
            }

            guard candidate.records[index].isActive,
                candidate.records[index].event.severity == .critical
            else { continue }

            let decision = evaluator.evaluate(
                candidate.records[index].event,
                configuration: candidate.configuration,
                now: now,
                calendar: calendar
            )
            var delivered = false
            for channel in ordered(candidate.records[index].deliveryPlan.channels) {
                guard decision.channels.contains(channel),
                    let delivery = candidate.records[index].deliveries[channel]
                else { continue }

                let isDue: Bool
                switch delivery.state {
                case .suppressed:
                    isDue = true
                case .queued, .failed:
                    isDue =
                        delivery.lastAttemptAt.map {
                            now.timeIntervalSince($0) >= Self.retrySeconds
                        } ?? true
                case .handedOff:
                    isDue =
                        decision.reminderSeconds.map { reminder in
                            delivery.lastAttemptAt.map {
                                now.timeIntervalSince($0) >= TimeInterval(reminder)
                            } ?? true
                        } ?? false
                }
                guard isDue else { continue }

                candidate.records[index].deliveries[channel] = NotificationChannelDelivery(
                    state: .queued, lastAttemptAt: now)
                effects.append(
                    NotificationEffect(
                        delivery: intent(
                            for: candidate.records[index], channel: channel)))
                delivered = true
                changed = true
            }
            if delivered {
                effects.append(
                    NotificationEffect(activeChange: .upsert(candidate.records[index])))
            }
        }

        let countBeforePrune = candidate.records.count
        pruneOldInactiveRecords(&candidate, now: now)
        changed = changed || candidate.records.count != countBeforePrune
        guard changed else { return [] }
        try store.save(candidate)
        state = candidate
        return effects
    }

    public func markDelivery(
        eventID: UUID,
        channel: NotificationChannel,
        state deliveryState: NotificationDeliveryState,
        attemptedAt: Date
    ) throws {
        guard let index = state.records.firstIndex(where: { $0.event.eventID == eventID }) else {
            throw NotificationEngineError.notificationNotFound
        }
        guard state.records[index].deliveryPlan.channels.contains(channel) else {
            throw NotificationEngineError.channelNotPlanned
        }
        var candidate = state
        candidate.records[index].deliveries[channel] = NotificationChannelDelivery(
            state: deliveryState,
            lastAttemptAt: attemptedAt
        )
        try store.save(candidate)
        state = candidate
    }

    public func replaceConfiguration(_ replacement: NotificationConfiguration) throws {
        let validated = try replacement.validated()
        var candidate = state
        candidate.configuration = validated
        try store.save(candidate)
        state = candidate
    }

    public func configuration() -> NotificationConfiguration {
        state.configuration
    }

    public func markPanelSoundAttempted(eventID: UUID, attemptedAt: Date) throws -> Bool {
        guard let index = state.records.firstIndex(where: { $0.event.eventID == eventID }) else {
            throw NotificationEngineError.notificationNotFound
        }
        guard state.records[index].panelSoundAttemptedAt == nil else { return false }
        var candidate = state
        candidate.records[index].panelSoundAttemptedAt = attemptedAt
        try store.save(candidate)
        state = candidate
        return true
    }

    public func history(
        limit: Int,
        before: NotificationHistoryCursor?
    ) -> NotificationHistoryPage {
        let boundedLimit = min(max(limit, 1), 100)
        let eligible = state.records
            .filter { record in
                guard let before else { return true }
                if record.lastSeenAt != before.lastSeenAt {
                    return record.lastSeenAt < before.lastSeenAt
                }
                return record.event.eventID.uuidString > before.eventID.uuidString
            }
            .sorted(by: Self.isMoreRecent)
        let page = Array(eligible.prefix(boundedLimit))
        let nextCursor =
            eligible.count > page.count
            ? page.last.map {
                NotificationHistoryCursor(
                    lastSeenAt: $0.lastSeenAt,
                    eventID: $0.event.eventID
                )
            }
            : nil
        return NotificationHistoryPage(records: page, nextCursor: nextCursor)
    }

    public func stateSummary() -> NotificationEngineSummary {
        NotificationEngineSummary(
            configuration: state.configuration,
            knownSources: state.knownSources,
            activeCriticalCount: state.records.count {
                $0.isActive && $0.event.severity == .critical
            },
            recentRecords: Array(state.records.sorted(by: Self.isMoreRecent).prefix(10))
        )
    }

    public func record(eventID: UUID) -> NotificationRecord? {
        state.records.first { $0.event.eventID == eventID }
    }

    public func activeRecords() -> [NotificationRecord] {
        state.records
            .filter { $0.isActive && $0.event.severity == .critical }
            .sorted(by: Self.isMoreRecent)
    }

    private func updateDeduplicatedRecord(
        at index: Int,
        input: NotificationIngress,
        state candidate: inout NotificationPersistentState,
        now: Date,
        calendar: Calendar
    ) -> [NotificationEffect] {
        var record = candidate.records[index]
        record.lastSeenAt = now
        record.occurrenceCount += 1
        candidate.knownSources.insert(input.sourceID)

        let escalated = severityRank(input.severity) > severityRank(record.event.severity)
        let mayReplaceEvent = escalated || !record.isActive
        if mayReplaceEvent {
            record.event = NotificationEvent(
                eventID: record.event.eventID,
                sourceID: input.sourceID,
                severity: input.severity,
                title: input.title,
                message: input.message,
                createdAt: input.createdAt,
                expiresAt: input.expiresAt,
                dedupKey: input.dedupKey
            )
        }
        if input.severity == .critical || record.event.severity == .critical {
            record.isActive = true
        }

        let previousDeliveryAt =
            record.deliveries.values.compactMap(\.lastAttemptAt).max()
            ?? record.firstSeenAt
        let currentDecision = evaluator.evaluate(
            record.event,
            configuration: candidate.configuration,
            now: now,
            calendar: calendar
        )
        let cooldownElapsed =
            now.timeIntervalSince(previousDeliveryAt)
            >= TimeInterval(currentDecision.cooldownSeconds)
        let shouldDeliver = escalated || cooldownElapsed

        var effects: [NotificationEffect] = []
        if shouldDeliver {
            apply(decision: currentDecision, to: &record, now: now)
            effects = effectsForNewDelivery(record)
        }
        candidate.records[index] = record
        return effects
    }

    private func makeRecord(
        input: NotificationIngress,
        decision: NotificationPolicyDecision,
        now: Date
    ) -> NotificationRecord {
        let channels = decision.channels.union(decision.suppressedChannels)
        var deliveries: [NotificationChannel: NotificationChannelDelivery] = [:]
        for channel in ordered(channels) {
            let suppressed = decision.suppressedChannels.contains(channel)
            deliveries[channel] = NotificationChannelDelivery(
                state: suppressed ? .suppressed : .queued,
                lastAttemptAt: suppressed ? nil : now
            )
        }
        return NotificationRecord(
            event: NotificationEvent(input),
            firstSeenAt: now,
            lastSeenAt: now,
            isActive: input.severity == .critical,
            deliveryPlan: NotificationDeliveryPlan(
                channels: channels,
                wakePanel: decision.wakePanel,
                panelSound: decision.panelSound
            ),
            deliveries: deliveries
        )
    }

    private func apply(
        decision: NotificationPolicyDecision,
        to record: inout NotificationRecord,
        now: Date
    ) {
        let channels = decision.channels.union(decision.suppressedChannels)
        record.deliveryPlan = NotificationDeliveryPlan(
            channels: channels,
            wakePanel: decision.wakePanel,
            panelSound: decision.panelSound
        )
        record.deliveries = Dictionary(
            uniqueKeysWithValues: ordered(channels).map { channel in
                let suppressed = decision.suppressedChannels.contains(channel)
                return (
                    channel,
                    NotificationChannelDelivery(
                        state: suppressed ? .suppressed : .queued,
                        lastAttemptAt: suppressed ? nil : now
                    )
                )
            })
    }

    private func effectsForNewDelivery(_ record: NotificationRecord) -> [NotificationEffect] {
        var effects: [NotificationEffect] = ordered(record.deliveryPlan.channels).compactMap {
            channel -> NotificationEffect? in
            guard record.deliveries[channel]?.state == .queued else { return nil }
            return NotificationEffect(delivery: intent(for: record, channel: channel))
        }
        if record.isActive {
            effects.append(NotificationEffect(activeChange: .upsert(record)))
        }
        return effects
    }

    private func intent(
        for record: NotificationRecord,
        channel: NotificationChannel
    ) -> NotificationDeliveryIntent {
        NotificationDeliveryIntent(
            eventID: record.event.eventID,
            channel: channel,
            wakePanel: channel == .panel && record.deliveryPlan.wakePanel,
            panelSound: channel == .panel ? record.deliveryPlan.panelSound : nil
        )
    }

    private func expireAndPrune(
        _ candidate: inout NotificationPersistentState,
        now: Date
    ) -> [NotificationEffect] {
        var effects: [NotificationEffect] = []
        for index in candidate.records.indices
        where candidate.records[index].isActive
            && candidate.records[index].event.expiresAt.map({ $0 <= now }) == true
        {
            candidate.records[index].isActive = false
            effects.append(
                NotificationEffect(
                    activeChange: .clear(candidate.records[index].event.eventID)))
        }
        pruneOldInactiveRecords(&candidate, now: now)
        return effects
    }

    private func pruneOldInactiveRecords(
        _ candidate: inout NotificationPersistentState,
        now: Date
    ) {
        let cutoff = now.addingTimeInterval(-Self.retentionSeconds)
        candidate.records.removeAll { !$0.isActive && $0.lastSeenAt < cutoff }
    }

    private func pruneKnownSources(_ candidate: inout NotificationPersistentState) {
        guard candidate.knownSources.count > Self.maximumKnownSources else { return }
        let referenced = Set(candidate.records.map(\.event.sourceID))
        let removable = candidate.knownSources.subtracting(referenced).sorted {
            $0.rawValue < $1.rawValue
        }
        let excess = candidate.knownSources.count - Self.maximumKnownSources
        for sourceID in removable.prefix(excess) {
            candidate.knownSources.remove(sourceID)
        }
    }

    private func makeRoomForNewRecord(
        _ candidate: inout NotificationPersistentState
    ) throws {
        guard candidate.records.count >= Self.maximumRecords else { return }
        let removable = candidate.records.enumerated()
            .filter { !$0.element.isActive }
            .sorted { $0.element.lastSeenAt < $1.element.lastSeenAt }
        var indexes = Set(
            removable.prefix(candidate.records.count - Self.maximumRecords + 1).map(\.offset))
        if !indexes.isEmpty {
            candidate.records = candidate.records.enumerated().compactMap { index, record in
                indexes.remove(index) == nil ? record : nil
            }
        }
        guard candidate.records.count < Self.maximumRecords else {
            throw NotificationEngineError.capacityReached
        }
    }

    private func newestRecordIndex(
        sourceID: NotificationSourceID,
        dedupKey: String,
        records: [NotificationRecord]
    ) -> Int? {
        records.indices
            .filter {
                records[$0].event.sourceID == sourceID
                    && records[$0].event.dedupKey == dedupKey
            }
            .max { records[$0].lastSeenAt < records[$1].lastSeenAt }
    }

    private func ordered(_ channels: Set<NotificationChannel>) -> [NotificationChannel] {
        NotificationChannel.allCases.filter(channels.contains)
    }

    private func severityRank(_ severity: NotificationSeverity) -> Int {
        switch severity {
        case .info: 0
        case .warning: 1
        case .critical: 2
        }
    }

    private static func isMoreRecent(_ lhs: NotificationRecord, _ rhs: NotificationRecord) -> Bool {
        if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
        return lhs.event.eventID.uuidString < rhs.event.eventID.uuidString
    }
}
