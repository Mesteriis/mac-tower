import Foundation

public enum CollectionFailure: String, Codable, Equatable, Sendable {
    case authorization
    case malformedResponse = "malformed_response"
    case transport
}

public struct StoredSnapshot: Codable, Equatable, Sendable {
    public let snapshot: AccountSnapshot
    public let lastAttemptAt: Date
    public let lastFailure: CollectionFailure?
    public let consecutiveFailures: Int

    public init(
        snapshot: AccountSnapshot,
        lastAttemptAt: Date,
        lastFailure: CollectionFailure?,
        consecutiveFailures: Int = 0
    ) {
        self.snapshot = snapshot
        self.lastAttemptAt = lastAttemptAt
        self.lastFailure = lastFailure
        self.consecutiveFailures = consecutiveFailures
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try container.decode(AccountSnapshot.self, forKey: .snapshot)
        lastAttemptAt = try container.decode(Date.self, forKey: .lastAttemptAt)
        lastFailure = try container.decodeIfPresent(CollectionFailure.self, forKey: .lastFailure)
        consecutiveFailures =
            try container.decodeIfPresent(
                Int.self, forKey: .consecutiveFailures) ?? 0
    }
}

public actor SnapshotStore {
    private var entries: [AccountID: StoredSnapshot] = [:]

    public init() {}

    public func recordSuccess(_ snapshot: AccountSnapshot, attemptedAt: Date) {
        entries[snapshot.id] = StoredSnapshot(
            snapshot: snapshot,
            lastAttemptAt: attemptedAt,
            lastFailure: nil,
            consecutiveFailures: 0
        )
    }

    public func recordFailure(
        accountID: AccountID,
        attemptedAt: Date,
        reason: CollectionFailure
    ) {
        guard let previous = entries[accountID] else { return }
        entries[accountID] = StoredSnapshot(
            snapshot: reason == .authorization
                ? AccountSnapshot(
                    id: previous.snapshot.id,
                    provider: previous.snapshot.provider,
                    label: previous.snapshot.label,
                    plan: previous.snapshot.plan,
                    status: .authorizationRequired,
                    source: previous.snapshot.source,
                    observedAt: previous.snapshot.observedAt,
                    quotas: previous.snapshot.quotas,
                    resetCredits: previous.snapshot.resetCredits,
                    balances: previous.snapshot.balances
                ) : previous.snapshot,
            lastAttemptAt: attemptedAt,
            lastFailure: reason,
            consecutiveFailures: previous.consecutiveFailures == Int.max
                ? Int.max : previous.consecutiveFailures + 1
        )
    }

    public func entry(for accountID: AccountID) -> StoredSnapshot? {
        entries[accountID]
    }

    public func all() -> [StoredSnapshot] {
        entries.values.sorted { $0.snapshot.id.rawValue < $1.snapshot.id.rawValue }
    }

    public func remove(accountID: AccountID) {
        entries.removeValue(forKey: accountID)
    }

    public func restore(_ restored: [StoredSnapshot]) {
        entries = Dictionary(uniqueKeysWithValues: restored.map { ($0.snapshot.id, $0) })
    }
}
