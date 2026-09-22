import Foundation

public enum ClaudeBridgeCommandError: Error, Equatable {
    case invalidArguments
}

public struct ClaudeBridgeCommand: Equatable, Sendable {
    public let accountID: AccountID
    public let label: String
    public let outputDirectory: URL

    public static func parse(_ arguments: [String]) throws -> ClaudeBridgeCommand {
        guard arguments.count == 6 else { throw ClaudeBridgeCommandError.invalidArguments }
        var values: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            values[arguments[index]] = arguments[index + 1]
        }
        guard let rawID = values["--account-id"],
            rawID.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]{0,63}/) != nil,
            let label = values["--label"],
            !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let outputPath = values["--output-directory"],
            outputPath.hasPrefix("/")
        else {
            throw ClaudeBridgeCommandError.invalidArguments
        }
        return ClaudeBridgeCommand(
            accountID: AccountID(rawID),
            label: label,
            outputDirectory: URL(fileURLWithPath: outputPath, isDirectory: true).standardizedFileURL
        )
    }
}

public struct ClaudeBridgeProcessor: Sendable {
    public init() {}

    @discardableResult
    public func process(
        _ input: Data,
        command: ClaudeBridgeCommand,
        receivedAt: Date = Date()
    ) throws -> AccountSnapshot {
        let storage = try PrivateFileStore(root: command.outputDirectory)
        let filename = "\(command.accountID.rawValue).json"
        let previous: AccountSnapshot?
        if let data = try storage.read(named: filename) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            previous = try? decoder.decode(AccountSnapshot.self, from: data)
        } else {
            previous = nil
        }

        var state = ClaudeTelemetryState(
            accountID: command.accountID,
            label: command.label,
            previousSnapshot: previous
        )
        let snapshot = try state.ingest(input, receivedAt: receivedAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try storage.write(try encoder.encode(snapshot), named: filename)
        return snapshot
    }
}
