import Foundation
import MacTowerCore

public enum PowerModeStoreError: Error, Equatable {
    case unsupportedVersion
}

public protocol PowerModeStore: Sendable {
    func load() throws -> PowerMode?
    func save(_ mode: PowerMode) throws
}

public struct FilePowerModeStore: PowerModeStore, Sendable {
    private struct Settings: Codable {
        let version: Int
        let mode: PowerMode
    }

    private let storage: PrivateFileStore

    public init(root: URL) throws {
        storage = try PrivateFileStore(root: root)
    }

    public func load() throws -> PowerMode? {
        guard let data = try storage.read(named: "power-control.json") else { return nil }
        let settings = try JSONDecoder().decode(Settings.self, from: data)
        guard settings.version == 1 else { throw PowerModeStoreError.unsupportedVersion }
        return settings.mode
    }

    public func save(_ mode: PowerMode) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try storage.write(
            try encoder.encode(Settings(version: 1, mode: mode)),
            named: "power-control.json"
        )
    }
}
