import Foundation

public struct AINotificationDetector: Sendable {
    public init() {}

    public func events(
        previous: [StoredSnapshot],
        current: [StoredSnapshot],
        configuration: AINotificationConfiguration,
        now: Date
    ) throws -> [NotificationIngress] {
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.snapshot.id, $0) })
        var events: [NotificationIngress] = []

        for entry in current.sorted(by: { $0.snapshot.id.rawValue < $1.snapshot.id.rawValue }) {
            guard let prior = old[entry.snapshot.id] else { continue }
            let snapshot = entry.snapshot
            let previousSnapshot = prior.snapshot

            if configuration.authorizationTransitionsEnabled {
                if previousSnapshot.status != .authorizationRequired,
                    snapshot.status == .authorizationRequired
                {
                    events.append(
                        try event(
                            provider: snapshot.provider, accountID: snapshot.id,
                            metric: "authorization", severity: .critical,
                            title: "AI authorization required",
                            message: "\(snapshot.provider.rawValue) account requires authorization",
                            now: now, state: "required"))
                } else if previousSnapshot.status == .authorizationRequired,
                    snapshot.status == .available
                {
                    events.append(
                        try event(
                            provider: snapshot.provider, accountID: snapshot.id,
                            metric: "authorization", severity: .info,
                            title: "AI authorization restored",
                            message: "\(snapshot.provider.rawValue) account authorization restored",
                            now: now, state: "restored"))
                }
            }

            for threshold in configuration.quotaThresholds where threshold.accountID == snapshot.id
            {
                guard
                    let before = previousSnapshot.quotas.first(where: { $0.id == threshold.quotaID }
                    ),
                    let after = snapshot.quotas.first(where: { $0.id == threshold.quotaID }),
                    before.remainingPercent > threshold.remainingPercent,
                    after.remainingPercent <= threshold.remainingPercent
                else { continue }
                events.append(
                    try event(
                        provider: snapshot.provider, accountID: snapshot.id,
                        metric: "quota.\(threshold.quotaID)", severity: .warning,
                        title: "AI quota is low",
                        message: "Remaining quota is \(after.remainingPercent)%",
                        now: now, state: "low"))
            }

            if configuration.quotaResetTransitionsEnabled,
                snapshot.observedAt > previousSnapshot.observedAt
            {
                for after in snapshot.quotas {
                    guard let before = previousSnapshot.quotas.first(where: { $0.id == after.id }),
                        after.resetsAt > before.resetsAt,
                        after.remainingPercent > before.remainingPercent
                    else { continue }
                    events.append(
                        try event(
                            provider: snapshot.provider, accountID: snapshot.id,
                            metric: "quota.\(after.id).reset", severity: .info,
                            title: "AI quota reset",
                            message: "Quota window reset was confirmed by fresh telemetry",
                            now: now, state: after.resetsAt.timeIntervalSince1970.description))
                }
            }

            for threshold in configuration.balanceThresholds
            where threshold.accountID == snapshot.id {
                guard let limit = decimal(threshold.amount),
                    let before = previousSnapshot.balances.first(where: {
                        $0.currency == threshold.currency
                    }).flatMap({ decimal($0.total) }),
                    let afterBalance = snapshot.balances.first(where: {
                        $0.currency == threshold.currency
                    }),
                    let after = decimal(afterBalance.total),
                    before > limit, after <= limit
                else { continue }
                events.append(
                    try event(
                        provider: snapshot.provider, accountID: snapshot.id,
                        metric: "balance.\(threshold.currency)", severity: .warning,
                        title: "AI balance is low",
                        message: "Balance is \(afterBalance.total.value) \(threshold.currency)",
                        now: now, state: "low"))
            }

            if let boundary = configuration.consecutiveFailureCount {
                if prior.consecutiveFailures < boundary,
                    entry.consecutiveFailures >= boundary,
                    entry.lastFailure != nil
                {
                    events.append(
                        try event(
                            provider: snapshot.provider, accountID: snapshot.id,
                            metric: "collection", severity: .warning,
                            title: "AI sensor collection failed",
                            message: "Collection failed \(entry.consecutiveFailures) times",
                            now: now, state: "failed"))
                } else if prior.consecutiveFailures >= boundary,
                    entry.consecutiveFailures == 0
                {
                    events.append(
                        try event(
                            provider: snapshot.provider, accountID: snapshot.id,
                            metric: "collection", severity: .info,
                            title: "AI sensor collection restored",
                            message: "Collection recovered",
                            now: now, state: "restored"))
                }
            }
        }
        return events
    }

    private func event(
        provider: AIProvider,
        accountID: AccountID,
        metric: String,
        severity: NotificationSeverity,
        title: String,
        message: String,
        now: Date,
        state: String
    ) throws -> NotificationIngress {
        let source = try NotificationSourceID(
            validating: sourceID(
                provider: provider, accountID: accountID, metric: metric))
        return NotificationIngress(
            eventID: UUID(),
            sourceID: source,
            severity: severity,
            title: title,
            message: message,
            createdAt: now,
            dedupKey: "\(source.rawValue).\(state)"
        )
    }

    private func sourceID(provider: AIProvider, accountID: AccountID, metric: String) -> String {
        let raw = "ai.\(provider.rawValue).\(accountID.rawValue).\(metric)"
        let sanitized = raw.map { character -> Character in
            character.isASCII
                && (character.isLetter || character.isNumber || "._-".contains(character))
                ? character : "_"
        }
        let readable = String(sanitized)
        guard readable.count > 64 else { return readable }
        return "\(readable.prefix(47)).\(fnv1a(raw))"
    }

    private func fnv1a(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    private func decimal(_ value: DecimalString) -> Decimal? {
        Decimal(string: value.value, locale: Locale(identifier: "en_US_POSIX"))
    }
}
