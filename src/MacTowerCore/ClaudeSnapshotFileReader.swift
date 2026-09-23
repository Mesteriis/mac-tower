import Darwin
import Foundation

public enum ClaudeSnapshotFileError: Error, Equatable {
    case unsafeFile
    case invalidSnapshot
}

public struct ClaudeSnapshotFileReader: Sendable {
    private let maximumBytes = 1_048_576

    public init() {}

    public func read(from url: URL, expectedID: AccountID) throws -> AccountSnapshot {
        let descriptor = open(url.standardizedFileURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ClaudeSnapshotFileError.unsafeFile }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_size > 0,
            metadata.st_size <= maximumBytes
        else {
            throw ClaudeSnapshotFileError.unsafeFile
        }

        guard
            let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd()
        else {
            throw ClaudeSnapshotFileError.invalidSnapshot
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(AccountSnapshot.self, from: data),
            snapshot.id == expectedID,
            snapshot.provider == .claude,
            snapshot.source == .claudeStatusline
        else {
            throw ClaudeSnapshotFileError.invalidSnapshot
        }
        return snapshot
    }
}
