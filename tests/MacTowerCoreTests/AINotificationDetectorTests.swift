import Foundation
import Testing

@testable import MacTowerCore

@Suite("AI notification transitions")
struct AINotificationDetectorTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var t1: Date { t0.addingTimeInterval(300) }
    private let id = AccountID("account-main")

    @Test("Authorization transitions emit once with stable identity independent of label")
    func authorization() throws {
        let config = AINotificationConfiguration(authorizationTransitionsEnabled: true)
        let detector = AINotificationDetector()
        let previous = stored(status: .available, label: "Private label", observedAt: t0)
        let current = stored(status: .authorizationRequired, label: "Changed label", observedAt: t1)

        let events = try detector.events(
            previous: [previous], current: [current], configuration: config, now: t1)
        #expect(events.count == 1)
        #expect(events[0].sourceID.rawValue == "ai.codex.account-main.authorization")
        #expect(!events[0].sourceID.rawValue.contains("Private"))
        #expect(
            try detector.events(
                previous: [current], current: [current], configuration: config, now: t1
            ).isEmpty)
    }

    @Test("Quota threshold crosses only from above and reset needs newer telemetry")
    func quotaTransitions() throws {
        let detector = AINotificationDetector()
        let threshold = AIQuotaNotificationThreshold(
            accountID: id, quotaID: "weekly", remainingPercent: 20)
        let config = AINotificationConfiguration(
            quotaResetTransitionsEnabled: true,
            quotaThresholds: [threshold]
        )
        let old = stored(remaining: 21, reset: t1, observedAt: t0)
        let low = stored(remaining: 19, reset: t1, observedAt: t1)
        #expect(
            try detector.events(previous: [old], current: [low], configuration: config, now: t1)
                .count == 1)

        let reset = stored(
            remaining: 100,
            reset: t1.addingTimeInterval(86_400),
            observedAt: t1.addingTimeInterval(1)
        )
        #expect(
            try detector.events(previous: [low], current: [reset], configuration: config, now: t1)
                .count == 1)
        let replay = stored(
            remaining: 100,
            reset: t1.addingTimeInterval(86_400),
            observedAt: low.snapshot.observedAt
        )
        #expect(
            try detector.events(previous: [low], current: [replay], configuration: config, now: t1)
                .isEmpty)
    }

    @Test("Missing quota and identical Claude telemetry produce nothing")
    func missingAndReplay() throws {
        let config = AINotificationConfiguration(
            quotaThresholds: [
                AIQuotaNotificationThreshold(
                    accountID: id, quotaID: "missing", remainingPercent: 20)
            ])
        var snapshot = stored(remaining: 10, observedAt: t0, provider: .claude)
        snapshot = StoredSnapshot(
            snapshot: AccountSnapshot(
                id: snapshot.snapshot.id,
                provider: .claude,
                label: "Claude",
                status: .available,
                source: .claudeStatusline,
                observedAt: t0,
                quotas: snapshot.snapshot.quotas
            ),
            lastAttemptAt: t1,
            lastFailure: nil
        )
        #expect(
            try AINotificationDetector().events(
                previous: [snapshot], current: [snapshot], configuration: config, now: t1
            ).isEmpty)
    }

    @Test("DeepSeek balances compare exact decimal values by currency")
    func decimalBalance() throws {
        let config = AINotificationConfiguration(
            balanceThresholds: [
                AIBalanceNotificationThreshold(
                    accountID: id,
                    currency: "USD",
                    amount: try DecimalString("0.10")
                )
            ])
        let previous = stored(balance: "0.1000000000000000001", observedAt: t0)
        let current = stored(balance: "0.10", observedAt: t1)
        let events = try AINotificationDetector().events(
            previous: [previous], current: [current], configuration: config, now: t1)
        #expect(events.count == 1)
        #expect(events[0].sourceID.rawValue == "ai.deepseek.account-main.balance.USD")
    }

    @Test("Failure boundary and recovery are transitions and old JSON defaults to zero")
    func failuresAndCompatibility() async throws {
        let store = SnapshotStore()
        await store.recordSuccess(snapshot(observedAt: t0), attemptedAt: t0)
        await store.recordFailure(accountID: id, attemptedAt: t1, reason: .transport)
        await store.recordFailure(accountID: id, attemptedAt: t1, reason: .transport)
        let failed = try #require(await store.entry(for: id))
        #expect(failed.consecutiveFailures == 2)

        let previous = StoredSnapshot(
            snapshot: failed.snapshot,
            lastAttemptAt: t0,
            lastFailure: .transport,
            consecutiveFailures: 1
        )
        let config = AINotificationConfiguration(consecutiveFailureCount: 2)
        #expect(
            try AINotificationDetector().events(
                previous: [previous], current: [failed], configuration: config, now: t1
            ).count == 1)
        let recovered = StoredSnapshot(
            snapshot: snapshot(observedAt: t1), lastAttemptAt: t1, lastFailure: nil)
        #expect(
            try AINotificationDetector().events(
                previous: [failed], current: [recovered], configuration: config, now: t1
            ).count == 1)

        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(recovered)) as? [String: Any])
        object.removeValue(forKey: "consecutiveFailures")
        let decoded = try JSONDecoder().decode(
            StoredSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.consecutiveFailures == 0)
    }

    private func stored(
        status: AccountStatus = .available,
        label: String = "Main",
        remaining: Double? = nil,
        reset: Date? = nil,
        balance: String? = nil,
        observedAt: Date,
        provider: AIProvider = .codex
    ) -> StoredSnapshot {
        StoredSnapshot(
            snapshot: snapshot(
                status: status, label: label, remaining: remaining, reset: reset,
                balance: balance, observedAt: observedAt, provider: provider),
            lastAttemptAt: observedAt,
            lastFailure: nil
        )
    }

    private func snapshot(
        status: AccountStatus = .available,
        label: String = "Main",
        remaining: Double? = nil,
        reset: Date? = nil,
        balance: String? = nil,
        observedAt: Date,
        provider: AIProvider = .codex
    ) -> AccountSnapshot {
        let quotas =
            remaining.map {
                [
                    QuotaWindow(
                        id: "weekly", name: nil, usedPercent: 100 - $0,
                        windowDurationMinutes: 10_080, resetsAt: reset ?? t1)
                ]
            } ?? []
        let balances =
            balance.map {
                [
                    MoneyBalance(
                        currency: "USD",
                        total: try! DecimalString($0),
                        granted: try! DecimalString("0"),
                        toppedUp: try! DecimalString($0))
                ]
            } ?? []
        return AccountSnapshot(
            id: id,
            provider: balance == nil ? provider : .deepSeek,
            label: label,
            status: status,
            source: balance == nil
                ? (provider == .claude ? .claudeStatusline : .codexAppServer) : .deepSeekAPI,
            observedAt: observedAt,
            quotas: quotas,
            balances: balances
        )
    }
}
