import Foundation

public enum NotificationStoreError: Error, Equatable, Sendable {
    case malformedState
    case unsupportedVersion
    case invalidConfiguration
    case invalidState
    case storageFailure
}

public struct NotificationPersistentState: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var configuration: NotificationConfiguration
    public var knownSources: Set<NotificationSourceID>
    public var records: [NotificationRecord]

    public init(
        version: Int = currentVersion,
        configuration: NotificationConfiguration,
        knownSources: Set<NotificationSourceID>,
        records: [NotificationRecord]
    ) {
        self.version = version
        self.configuration = configuration
        self.knownSources = knownSources
        self.records = records
    }

    public static let empty = NotificationPersistentState(
        configuration: .disabled,
        knownSources: [],
        records: []
    )
}

public protocol NotificationStateStore: Sendable {
    func load() throws -> NotificationPersistentState
    func save(_ state: NotificationPersistentState) throws
}

public struct FileNotificationStateStore: NotificationStateStore, Sendable {
    public static let fileName = "notifications.json"

    private let storage: PrivateFileStore

    public init(root: URL) throws {
        do {
            storage = try PrivateFileStore(root: root)
        } catch {
            throw NotificationStoreError.storageFailure
        }
    }

    public func load() throws -> NotificationPersistentState {
        let data: Data
        do {
            guard let stored = try storage.read(named: Self.fileName) else { return .empty }
            data = stored
        } catch {
            throw NotificationStoreError.storageFailure
        }

        let version: VersionEnvelope
        do {
            version = try JSONDecoder().decode(VersionEnvelope.self, from: data)
        } catch {
            throw NotificationStoreError.malformedState
        }
        guard version.version == NotificationPersistentState.currentVersion else {
            throw NotificationStoreError.unsupportedVersion
        }

        let state: NotificationPersistentState
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            state = try decoder.decode(NotificationPersistentState.self, from: data)
        } catch {
            throw NotificationStoreError.malformedState
        }
        try validate(state)
        return state
    }

    public func save(_ state: NotificationPersistentState) throws {
        try validate(state)
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(state)
        } catch let error as NotificationStoreError {
            throw error
        } catch {
            throw NotificationStoreError.invalidState
        }
        do {
            try storage.write(data, named: Self.fileName)
        } catch {
            throw NotificationStoreError.storageFailure
        }
    }

    private func validate(_ state: NotificationPersistentState) throws {
        guard state.version == NotificationPersistentState.currentVersion else {
            throw NotificationStoreError.unsupportedVersion
        }
        do {
            try state.configuration.validated()
        } catch {
            throw NotificationStoreError.invalidConfiguration
        }
        guard state.records.count <= 5_000,
            state.records.allSatisfy({ record in
                record.event.schemaVersion == 1 && record.occurrenceCount > 0
                    && state.knownSources.contains(record.event.sourceID)
                    && record.deliveryPlan.channels == Set(record.deliveries.keys)
                    && (!record.deliveryPlan.wakePanel
                        || record.deliveryPlan.channels.contains(.panel))
                    && (record.deliveryPlan.panelSound == nil
                        || record.deliveryPlan.channels.contains(.panel))
            })
        else {
            throw NotificationStoreError.invalidState
        }
    }
}

private struct VersionEnvelope: Decodable {
    let version: Int
}
