import Darwin
import Foundation

public enum PrivateFileStoreError: Error, Equatable {
    case unsafeRoot
    case invalidName
    case ioFailure
}

public struct PrivateFileStore: Sendable {
    public let root: URL

    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        try Self.prepareRoot(self.root)
    }

    public func write(_ data: Data, named name: String) throws {
        let destination = try fileURL(named: name)
        if Self.isSymbolicLink(destination.path) {
            throw PrivateFileStoreError.ioFailure
        }

        let temporary = root.appending(path: ".\(name).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw PrivateFileStoreError.ioFailure }

        var succeeded = false
        defer {
            close(descriptor)
            if !succeeded { unlink(temporary.path) }
        }

        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(
                        descriptor,
                        buffer.baseAddress?.advanced(by: offset),
                        buffer.count - offset
                    )
                    guard count > 0 else { throw PrivateFileStoreError.ioFailure }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0,
                rename(temporary.path, destination.path) == 0,
                chmod(destination.path, 0o600) == 0
            else {
                throw PrivateFileStoreError.ioFailure
            }
            succeeded = true
        } catch let error as PrivateFileStoreError {
            throw error
        } catch {
            throw PrivateFileStoreError.ioFailure
        }
    }

    public func read(named name: String) throws -> Data? {
        let source = try fileURL(named: name)
        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw PrivateFileStoreError.ioFailure
        }
        return try FileHandle(fileDescriptor: descriptor, closeOnDealloc: true).readToEnd()
    }

    public func remove(named name: String) throws {
        let file = try fileURL(named: name)
        if Self.isSymbolicLink(file.path) { throw PrivateFileStoreError.ioFailure }
        if unlink(file.path) != 0, errno != ENOENT {
            throw PrivateFileStoreError.ioFailure
        }
    }

    private func fileURL(named name: String) throws -> URL {
        guard name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]{0,127}/) != nil else {
            throw PrivateFileStoreError.invalidName
        }
        return root.appending(path: name)
    }

    private static func prepareRoot(_ root: URL) throws {
        if isSymbolicLink(root.path) { throw PrivateFileStoreError.unsafeRoot }
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard chmod(root.path, 0o700) == 0 else { throw PrivateFileStoreError.ioFailure }
        } catch let error as PrivateFileStoreError {
            throw error
        } catch {
            throw PrivateFileStoreError.ioFailure
        }
    }

    private static func isSymbolicLink(_ path: String) -> Bool {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { return false }
        return metadata.st_mode & S_IFMT == S_IFLNK
    }
}
