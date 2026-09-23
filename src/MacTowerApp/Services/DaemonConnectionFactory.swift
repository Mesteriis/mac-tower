import Darwin
import Foundation
import MacTowerCore

enum DaemonConnectionFactory {
    static func makeConnection() throws -> NSXPCConnection {
        let manifestURL = URL(fileURLWithPath: "/Library/Preferences/dev.mactower.trust.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw DaemonClientError.serviceNotInstalled
        }
        var metadata = stat()
        guard lstat(manifestURL.path, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_uid == 0,
            metadata.st_mode & 0o022 == 0,
            metadata.st_size <= 16_384
        else { throw DaemonClientError.invalidTrustManifest }
        let data = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
        let manifest = try JSONDecoder().decode(TrustManifest.self, from: data)
        guard manifest.ownerUID == getuid() else { throw DaemonClientError.rejected }

        let connection = NSXPCConnection(
            machServiceName: "dev.mactower.daemon", options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: MacTowerDaemonXPCProtocol.self)
        connection.setCodeSigningRequirement(try manifest.daemonRequirement())
        return connection
    }
}
