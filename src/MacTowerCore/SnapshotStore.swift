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
}

public actor SnapshotStore {
    private var entries: [AccountID: StoredSnapshot] = [:]

    public init() {}

    public func recordSuccess(_ snapshot: AccountSnapshot, attemptedAt: Date) {
        entries[snapshot.id] = StoredSnapshot(
            snapshot: snapshot,
            lastAttemptAt: attemptedAt,
            lastFailure: nil
        )
    }

    public func recordFailure(
        accountID: AccountID,
        attemptedAt: Date,
        reason: CollectionFailure
    ) {
        guard let previous = entries[accountID] else { return }
        entries[accountID] = StoredSnapshot(
            snapshot: previous.snapshot,
            lastAttemptAt: attemptedAt,
            lastFailure: reason
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
}
