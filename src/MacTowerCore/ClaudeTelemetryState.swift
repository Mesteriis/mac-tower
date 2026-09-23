import Foundation

public struct ClaudeTelemetryState: Sendable {
    private let accountID: AccountID
    private let label: String
    private var lastSnapshot: AccountSnapshot?

    public init(
        accountID: AccountID,
        label: String,
        previousSnapshot: AccountSnapshot? = nil
    ) {
        self.accountID = accountID
        self.label = label
        lastSnapshot = previousSnapshot
    }

    public mutating func ingest(_ data: Data, receivedAt: Date) throws -> AccountSnapshot {
        let parsed = try ClaudeStatuslineParser().parse(
            data,
            accountID: accountID,
            label: label,
            observedAt: receivedAt
        )
        let observedAt =
            lastSnapshot?.quotas == parsed.quotas
            ? lastSnapshot?.observedAt ?? receivedAt : receivedAt
        let snapshot = AccountSnapshot(
            id: parsed.id,
            provider: parsed.provider,
            label: parsed.label,
            plan: parsed.plan,
            status: parsed.status,
            source: parsed.source,
            observedAt: observedAt,
            quotas: parsed.quotas,
            resetCredits: parsed.resetCredits,
            balances: parsed.balances
        )
        lastSnapshot = snapshot
        return snapshot
    }
}
