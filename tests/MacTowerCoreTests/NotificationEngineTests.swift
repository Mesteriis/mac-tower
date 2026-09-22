import Foundation
import Testing

@testable import MacTowerCore

@Suite("Notification engine")
struct NotificationEngineTests {
    private let now = Date(timeIntervalSince1970: 1_790_102_100)

    @Test("State is saved before delivery effects are returned")
    func savePrecedesEffects() async throws {
        let store = RecordingNotificationStore(
            state: state(configuration: configuration(route: route([.mqtt, .mac]))))
        let engine = try NotificationEngine(store: store)

        let effects = try await engine.ingest(input(), now: now, calendar: utcCalendar)

        #expect(store.savedStates.count == 1)
        #expect(store.savedStates.last?.records.count == 1)
        #expect(effects.compactMap(\.delivery?.channel) == [.mqtt, .mac])
    }

    @Test("Concurrent duplicate IDs create one record and one delivery transition")
    func concurrentDuplicateIsSerialized() async throws {
        let store = RecordingNotificationStore(
            state: state(configuration: configuration(route: route([.mqtt]))))
        let engine = try NotificationEngine(store: store)
        let event = input()

        let effectCounts = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await engine.ingest(event, now: self.now, calendar: self.utcCalendar).count
                }
            }
            var counts: [Int] = []
            for try await count in group { counts.append(count) }
            return counts
        }

        #expect(effectCounts.filter { $0 > 0 }.count == 1)
        #expect((await engine.history(limit: 100, before: nil)).records.count == 1)
        #expect(store.savedStates.count == 1)
    }

    @Test("Deduplication increments one record and cooldown controls repeat delivery")
    func deduplicationAndCooldown() async throws {
        let store = RecordingNotificationStore(
            state: state(
                configuration: configuration(
                    route: route([.mqtt], cooldownSeconds: 60))))
        let engine = try NotificationEngine(store: store)

        let first = try await engine.ingest(
            input(id: uuid(1), dedupKey: "incident"), now: now, calendar: utcCalendar)
        let inside = try await engine.ingest(
            input(id: uuid(2), dedupKey: "incident"),
            now: now.addingTimeInterval(59),
            calendar: utcCalendar
        )
        let boundary = try await engine.ingest(
            input(id: uuid(3), dedupKey: "incident"),
            now: now.addingTimeInterval(60),
            calendar: utcCalendar
        )

        #expect(first.compactMap(\.delivery).count == 1)
        #expect(inside.compactMap(\.delivery).isEmpty)
        #expect(boundary.compactMap(\.delivery).count == 1)
        let records = await engine.history(limit: 100, before: nil).records
        #expect(records.count == 1)
        #expect(records[0].occurrenceCount == 3)
        #expect(records[0].event.eventID == uuid(1))
    }

    @Test("Escalation delivers immediately and an active critical cannot downgrade")
    func escalationAndNoDowngrade() async throws {
        let routes: [NotificationSeverity: NotificationRoute] = [
            .info: route([.mqtt], cooldownSeconds: 300),
            .warning: route([.mqtt], cooldownSeconds: 300),
            .critical: route([.mqtt, .mac], cooldownSeconds: 300),
        ]
        let configuration = try NotificationConfiguration(
            enabled: true,
            globalRule: NotificationRule(deliveries: routes)
        ).validated()
        let engine = try NotificationEngine(
            store: RecordingNotificationStore(state: state(configuration: configuration)))

        _ = try await engine.ingest(
            input(id: uuid(1), severity: .warning, dedupKey: "incident"),
            now: now,
            calendar: utcCalendar
        )
        let escalated = try await engine.ingest(
            input(id: uuid(2), severity: .critical, dedupKey: "incident"),
            now: now.addingTimeInterval(1),
            calendar: utcCalendar
        )
        let downgrade = try await engine.ingest(
            input(id: uuid(3), severity: .info, dedupKey: "incident"),
            now: now.addingTimeInterval(2),
            calendar: utcCalendar
        )

        #expect(escalated.compactMap(\.delivery?.channel) == [.mqtt, .mac])
        #expect(downgrade.compactMap(\.delivery).isEmpty)
        let record = try #require(await engine.history(limit: 1, before: nil).records.first)
        #expect(record.event.severity == .critical)
        #expect(record.isActive)
    }

    @Test("Quiet ordinary events stay suppressed while critical releases once")
    func quietHoursReleaseOnlyCritical() async throws {
        let quiet = try QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
        let rule = NotificationRule(
            deliveries: [
                .info: route([.mac]),
                .critical: route([.mac]),
            ],
            quietHours: quiet
        )
        let configuration = try NotificationConfiguration(
            enabled: true, globalRule: rule
        ).validated()
        let engine = try NotificationEngine(
            store: RecordingNotificationStore(state: state(configuration: configuration)))
        let quietTime = date("2026-09-22T23:00:00Z")
        let afterQuiet = date("2026-09-23T08:00:00Z")

        let ordinary = try await engine.ingest(
            input(id: uuid(1), severity: .info), now: quietTime, calendar: utcCalendar)
        let critical = try await engine.ingest(
            input(id: uuid(2), severity: .critical), now: quietTime, calendar: utcCalendar)
        let due = try await engine.dueEffects(now: afterQuiet, calendar: utcCalendar)
        let repeated = try await engine.dueEffects(
            now: afterQuiet.addingTimeInterval(1), calendar: utcCalendar)

        #expect(ordinary.compactMap(\.delivery).isEmpty)
        #expect(critical.compactMap(\.delivery).isEmpty)
        #expect(due.compactMap(\.delivery?.eventID) == [uuid(2)])
        #expect(repeated.compactMap(\.delivery).isEmpty)
    }

    @Test("Critical reminders respect their exact boundary")
    func reminderBoundary() async throws {
        let configuration = configuration(
            route: route([.mac], reminderSeconds: 60), severity: .critical)
        let engine = try NotificationEngine(
            store: RecordingNotificationStore(state: state(configuration: configuration)))
        let event = input(severity: .critical)
        _ = try await engine.ingest(event, now: now, calendar: utcCalendar)
        try await engine.markDelivery(
            eventID: event.eventID, channel: .mac, state: .handedOff, attemptedAt: now)

        #expect(
            try await engine.dueEffects(
                now: now.addingTimeInterval(59), calendar: utcCalendar
            ).compactMap(\.delivery).isEmpty)
        #expect(
            try await engine.dueEffects(
                now: now.addingTimeInterval(60), calendar: utcCalendar
            ).compactMap(\.delivery?.channel) == [.mac])
    }

    @Test("Acknowledgement is idempotent and clears only active critical")
    func acknowledgementLifecycle() async throws {
        let engine = try NotificationEngine(
            store: RecordingNotificationStore(
                state: state(
                    configuration: configuration(
                        route: route([.mqtt]), severity: .critical))))
        let event = input(severity: .critical)
        _ = try await engine.ingest(event, now: now, calendar: utcCalendar)

        let first = try await engine.acknowledge(
            eventID: event.eventID, actor: .mac, now: now.addingTimeInterval(1))
        let second = try await engine.acknowledge(
            eventID: event.eventID, actor: .mac, now: now.addingTimeInterval(2))

        #expect(first.compactMap(\.activeChange) == [.clear(event.eventID)])
        #expect(second.isEmpty)
        #expect((await engine.stateSummary()).activeCriticalCount == 0)
        await #expect(throws: NotificationEngineError.notificationNotFound) {
            try await engine.acknowledge(
                eventID: uuid(99), actor: .mac, now: now.addingTimeInterval(3))
        }
    }

    @Test("Expiry clears active state but retains history")
    func expiryClearsActive() async throws {
        let engine = try NotificationEngine(
            store: RecordingNotificationStore(
                state: state(
                    configuration: configuration(
                        route: route([.mqtt]), severity: .critical))))
        let event = input(
            severity: .critical,
            expiresAt: now.addingTimeInterval(60))
        _ = try await engine.ingest(event, now: now, calendar: utcCalendar)

        let effects = try await engine.dueEffects(
            now: now.addingTimeInterval(60), calendar: utcCalendar)

        #expect(effects.compactMap(\.activeChange) == [.clear(event.eventID)])
        #expect((await engine.stateSummary()).activeCriticalCount == 0)
        #expect(await engine.history(limit: 100, before: nil).records.count == 1)
    }

    @Test("Retention prunes old ordinary records but keeps old active critical")
    func retentionKeepsActiveCritical() async throws {
        let source = try NotificationSourceID(validating: "source")
        let old = now.addingTimeInterval(-31 * 86_400)
        let active = record(
            id: uuid(1), source: source, severity: .critical, time: old, active: true)
        let ordinary = record(
            id: uuid(2), source: source, severity: .info, time: old, active: false)
        let configuration = configuration(route: route([]))
        let store = RecordingNotificationStore(
            state: NotificationPersistentState(
                configuration: configuration,
                knownSources: [source],
                records: [active, ordinary]))
        let engine = try NotificationEngine(store: store)

        _ = try await engine.ingest(input(id: uuid(3)), now: now, calendar: utcCalendar)

        let records = await engine.history(limit: 100, before: nil).records
        #expect(records.map(\.event.eventID).contains(uuid(1)))
        #expect(!records.map(\.event.eventID).contains(uuid(2)))
        #expect(records.map(\.event.eventID).contains(uuid(3)))
    }

    @Test("History cursor does not skip records sharing a timestamp")
    func historyCursorBreaksTimestampTies() async throws {
        let source = try NotificationSourceID(validating: "source")
        let records = (0..<101).map {
            record(
                id: indexedUUID($0),
                source: source,
                severity: .info,
                time: now,
                active: false)
        }
        let engine = try NotificationEngine(
            store: RecordingNotificationStore(
                state: NotificationPersistentState(
                    configuration: configuration(route: route([])),
                    knownSources: [source],
                    records: records)))

        let first = await engine.history(limit: 100, before: nil)
        let second = await engine.history(limit: 100, before: first.nextCursor)

        #expect(first.records.count == 100)
        #expect(second.records.count == 1)
        #expect(
            Set(first.records.map(\.event.eventID)).isDisjoint(
                with: Set(second.records.map(\.event.eventID))))
    }

    @Test("Five thousand active critical records reject further growth")
    func capacityRejectsNewEvent() async throws {
        let source = try NotificationSourceID(validating: "source")
        let records = (0..<5_000).map { index in
            record(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                source: source,
                severity: .critical,
                time: now,
                active: true
            )
        }
        let store = RecordingNotificationStore(
            state: NotificationPersistentState(
                configuration: configuration(route: route([])),
                knownSources: [source],
                records: records))
        let engine = try NotificationEngine(store: store)

        await #expect(throws: NotificationEngineError.capacityReached) {
            try await engine.ingest(input(id: uuid(99)), now: now, calendar: utcCalendar)
        }
        #expect(await engine.history(limit: 100, before: nil).records.count == 100)
        #expect(store.savedStates.isEmpty)
    }

    @Test("Discovered source memory remains bounded")
    func knownSourcesAreBounded() async throws {
        let sources = try Set(
            (0..<5_000).map {
                try NotificationSourceID(validating: "source-\($0)")
            })
        let store = RecordingNotificationStore(
            state: NotificationPersistentState(
                configuration: configuration(route: route([])),
                knownSources: sources,
                records: []))
        let engine = try NotificationEngine(store: store)

        _ = try await engine.ingest(
            input(id: uuid(1), source: "current"), now: now, calendar: utcCalendar)

        let summary = await engine.stateSummary()
        #expect(summary.knownSources.count == 5_000)
        #expect(summary.knownSources.contains(try NotificationSourceID(validating: "current")))
    }

    @Test("Per-source and global one-minute rate limits are finite")
    func rateLimits() async throws {
        let perSourceEngine = try NotificationEngine(
            store: RecordingNotificationStore(
                state: state(configuration: configuration(route: route([])))))
        for index in 0..<30 {
            _ = try await perSourceEngine.ingest(
                input(id: indexedUUID(index), source: "source"),
                now: now,
                calendar: utcCalendar
            )
        }
        await #expect(throws: NotificationEngineError.rateLimited) {
            try await perSourceEngine.ingest(
                input(id: indexedUUID(31), source: "source"),
                now: now,
                calendar: utcCalendar
            )
        }

        let globalEngine = try NotificationEngine(
            store: RecordingNotificationStore(
                state: state(configuration: configuration(route: route([])))))
        for index in 0..<300 {
            _ = try await globalEngine.ingest(
                input(id: indexedUUID(index), source: "source-\(index / 30)"),
                now: now,
                calendar: utcCalendar
            )
        }
        await #expect(throws: NotificationEngineError.rateLimited) {
            try await globalEngine.ingest(
                input(id: indexedUUID(400), source: "source-10"),
                now: now,
                calendar: utcCalendar
            )
        }
    }

    @Test("Expired rate-limit source buckets are discarded")
    func rateLimiterDropsExpiredSources() throws {
        var limiter = NotificationRateLimiter()
        for index in 0..<300 {
            #expect(
                limiter.admit(
                    sourceID: try NotificationSourceID(validating: "source-\(index)"),
                    now: now))
        }

        #expect(
            limiter.admit(
                sourceID: try NotificationSourceID(validating: "current"),
                now: now.addingTimeInterval(60)))
        #expect(limiter.trackedSourceCount == 1)
    }

    @Test("Restart restores active critical only and sound attempt is durable")
    func restartRecoveryAndSoundAttempt() async throws {
        let source = try NotificationSourceID(validating: "source")
        var active = record(
            id: uuid(1), source: source, severity: .critical, time: now, active: true,
            channels: [.mac, .panel])
        active.deliveries[.mac] = NotificationChannelDelivery(state: .queued)
        active.deliveries[.panel] = NotificationChannelDelivery(state: .queued)
        var ordinary = record(
            id: uuid(2), source: source, severity: .info, time: now, active: false,
            channels: [.mac])
        ordinary.deliveries[.mac] = NotificationChannelDelivery(state: .queued)
        let store = RecordingNotificationStore(
            state: NotificationPersistentState(
                configuration: configuration(
                    route: route([.mac, .panel]), severity: .critical),
                knownSources: [source],
                records: [active, ordinary]))
        let engine = try NotificationEngine(store: store)

        #expect(
            try await engine.markPanelSoundAttempted(
                eventID: active.event.eventID, attemptedAt: now))
        #expect(
            try await !engine.markPanelSoundAttempted(
                eventID: active.event.eventID, attemptedAt: now.addingTimeInterval(1)))
        let due = try await engine.dueEffects(now: now, calendar: utcCalendar)

        #expect(Set(due.compactMap(\.delivery?.eventID)) == [active.event.eventID])
        #expect(!due.compactMap(\.delivery?.eventID).contains(ordinary.event.eventID))
        #expect(
            await engine.history(limit: 100, before: nil).records
                .first(where: { $0.event.eventID == active.event.eventID })?
                .panelSoundAttemptedAt == now)
    }

    @Test("A failed save returns no effects and leaves actor state unchanged")
    func failedSaveIsAtomic() async throws {
        let store = RecordingNotificationStore(
            state: state(configuration: configuration(route: route([.mqtt]))))
        store.failSaves = true
        let engine = try NotificationEngine(store: store)

        await #expect(throws: RecordingStoreError.saveFailed) {
            try await engine.ingest(input(), now: now, calendar: utcCalendar)
        }
        #expect(await engine.history(limit: 100, before: nil).records.isEmpty)
        #expect(store.savedStates.isEmpty)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func configuration(
        route: NotificationRoute,
        severity: NotificationSeverity = .info
    ) -> NotificationConfiguration {
        try! NotificationConfiguration(
            enabled: true,
            globalRule: NotificationRule(deliveries: [severity: route])
        ).validated()
    }

    private func route(
        _ channels: Set<NotificationChannel>,
        cooldownSeconds: Int = 0,
        reminderSeconds: Int? = nil
    ) -> NotificationRoute {
        NotificationRoute(
            channels: channels,
            cooldownSeconds: cooldownSeconds,
            reminderSeconds: reminderSeconds
        )
    }

    private func state(configuration: NotificationConfiguration) -> NotificationPersistentState {
        NotificationPersistentState(
            configuration: configuration,
            knownSources: [],
            records: []
        )
    }

    private func input(
        id: UUID = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
        source: String = "source",
        severity: NotificationSeverity = .info,
        dedupKey: String? = nil,
        expiresAt: Date? = nil
    ) -> NotificationIngress {
        NotificationIngress(
            eventID: id,
            sourceID: try! NotificationSourceID(validating: source),
            severity: severity,
            title: "Title",
            message: "Message",
            createdAt: now,
            expiresAt: expiresAt,
            dedupKey: dedupKey
        )
    }

    private func record(
        id: UUID,
        source: NotificationSourceID,
        severity: NotificationSeverity,
        time: Date,
        active: Bool,
        channels: Set<NotificationChannel> = []
    ) -> NotificationRecord {
        NotificationRecord(
            event: NotificationEvent(
                eventID: id,
                sourceID: source,
                severity: severity,
                title: "Title",
                message: "Message",
                createdAt: time
            ),
            firstSeenAt: time,
            lastSeenAt: time,
            isActive: active,
            deliveryPlan: NotificationDeliveryPlan(channels: channels),
            deliveries: Dictionary(
                uniqueKeysWithValues: channels.map {
                    ($0, NotificationChannelDelivery(state: .handedOff, lastAttemptAt: time))
                })
        )
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "550e8400-e29b-41d4-a716-%012d", suffix))!
    }

    private func indexedUUID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func event(
        _ severity: NotificationSeverity,
        _ source: NotificationSourceID
    ) -> NotificationEvent {
        NotificationEvent(
            eventID: uuid(1),
            sourceID: source,
            severity: severity,
            title: "Title",
            message: "Message",
            createdAt: now
        )
    }
}

private enum RecordingStoreError: Error, Equatable {
    case saveFailed
}

private final class RecordingNotificationStore: NotificationStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedState: NotificationPersistentState
    private var recordedStates: [NotificationPersistentState] = []
    private var shouldFailSaves = false

    init(state: NotificationPersistentState) {
        storedState = state
    }

    var savedStates: [NotificationPersistentState] {
        lock.withLock { recordedStates }
    }

    var failSaves: Bool {
        get { lock.withLock { shouldFailSaves } }
        set { lock.withLock { shouldFailSaves = newValue } }
    }

    func load() throws -> NotificationPersistentState {
        lock.withLock { storedState }
    }

    func save(_ state: NotificationPersistentState) throws {
        try lock.withLock {
            if shouldFailSaves { throw RecordingStoreError.saveFailed }
            storedState = state
            recordedStates.append(state)
        }
    }
}
