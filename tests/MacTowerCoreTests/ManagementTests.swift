import Foundation
import Testing

@testable import MacTowerCore

@Suite("Privileged management contract")
struct ManagementTests {
    @Test("Only finite management operations decode")
    func finiteOperations() throws {
        let decoder = JSONDecoder()
        let status = try decoder.decode(
            ManagementEnvelope.self,
            from: Data(#"{"operation":"status","payload":null}"#.utf8)
        )
        #expect(status.operation == .status)
        #expect(throws: DecodingError.self) {
            try decoder.decode(
                ManagementEnvelope.self,
                from: Data(#"{"operation":"run_shell","payload":null}"#.utf8)
            )
        }
    }

    @Test("Provider registrations validate their bounded source")
    func accountRegistrations() throws {
        let codex = try AccountRegistration.codex(
            id: AccountID("codex-personal"), label: "Personal")
        let claude = try AccountRegistration.claude(
            id: AccountID("claude-work"),
            label: "Work",
            snapshotPath:
                "/Users/person/Library/Application Support/MacTower/claude/claude-work.json"
        )
        let deepSeek = try AccountRegistration.deepSeek(
            id: AccountID("deepseek-main"), label: "Main")

        #expect(codex.provider == .codex)
        #expect(codex.codexHomeName == "codex-personal")
        #expect(claude.provider == .claude)
        #expect(claude.claudeSnapshotPath?.hasPrefix("/") == true)
        #expect(deepSeek.deepSeekSecretName == "deepseek-main.key")
        #expect(throws: AccountRegistrationError.self) {
            try AccountRegistration.claude(
                id: AccountID("../escape"), label: "Bad", snapshotPath: "relative.json")
        }
        #expect(throws: AccountRegistrationError.self) {
            try AccountRegistration.cursor(id: AccountID("cursor"), label: "Soon")
        }
    }

    @Test("Private DeepSeek request redacts its key from diagnostics")
    func deepSeekManagementRedaction() throws {
        let request = try AddDeepSeekAccountRequest(
            id: AccountID("deepseek-main"),
            label: "Main",
            apiKey: "test-private-key"
        )
        #expect(request.redactedDescription == "Add DeepSeek account deepseek-main")
        #expect(!request.redactedDescription.contains("test-private-key"))
    }

    @Test("Network settings reject enabled HTTP without an allowlist")
    func networkSettingsBoundary() throws {
        let http = try HTTPServiceConfiguration(
            enabled: true,
            bindAddress: "192.168.50.10",
            port: 8787,
            allowedNetworks: []
        )
        #expect(throws: ServiceConfigurationError.self) {
            try ServiceConfiguration(pollIntervalSeconds: 300, http: http)
                .validateForActivation()
        }
        let publicHTTP = try HTTPServiceConfiguration(
            enabled: true,
            bindAddress: "203.0.113.10",
            port: 8787,
            allowedNetworks: [try IPv4CIDR("0.0.0.0/0")]
        )
        #expect(throws: ServiceConfigurationError.self) {
            try ServiceConfiguration(http: publicHTTP).validateForActivation()
        }
        #expect(throws: ServiceConfigurationError.self) {
            try MQTTServiceConfiguration(enabled: true, host: "", port: 1883)
        }
        #expect(throws: ServiceConfigurationError.self) {
            try MQTTServiceConfiguration(
                enabled: true,
                host: "broker.local",
                port: 1883,
                topicPrefix: "mac_tower/#"
            )
        }
    }

    @Test("Trust manifest produces exact cdhash requirements and rejects malformed hashes")
    func trustRequirements() throws {
        let manifest = TrustManifest(
            ownerUID: 501,
            appCDHash: "0123456789abcdef0123456789abcdef01234567",
            daemonCDHash: "89abcdef0123456789abcdef0123456789abcdef"
        )
        #expect(
            try manifest.appRequirement() == #"cdhash H"0123456789abcdef0123456789abcdef01234567""#)
        #expect(
            try manifest.daemonRequirement()
                == #"cdhash H"89abcdef0123456789abcdef0123456789abcdef""#)
        #expect(throws: TrustManifestError.self) {
            try TrustManifest(ownerUID: 501, appCDHash: "bad", daemonCDHash: "also-bad")
                .appRequirement()
        }
    }

    @Test("Claude snapshots are read without following links and must match the registration")
    func claudeSnapshotBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = AccountSnapshot(
            id: AccountID("claude-main"),
            provider: .claude,
            label: "Main",
            status: .available,
            source: .claudeStatusline,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let file = root.appending(path: "snapshot.json")
        try encoder.encode(snapshot).write(to: file)

        let reader = ClaudeSnapshotFileReader()
        #expect(try reader.read(from: file, expectedID: snapshot.id) == snapshot)
        #expect(throws: ClaudeSnapshotFileError.self) {
            try reader.read(from: file, expectedID: AccountID("another-account"))
        }

        let link = root.appending(path: "linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: ClaudeSnapshotFileError.self) {
            try reader.read(from: link, expectedID: snapshot.id)
        }
    }

    @Test("Claude bridge preserves and restores the existing statusline")
    func claudeStatuslineInstallation() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let settingsURL = root.appending(path: "settings.json")
        let original: [String: Any] = [
            "theme": "dark",
            "statusLine": ["type": "command", "command": "printf old", "padding": 2],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: settingsURL)
        let output = root.appending(path: "snapshots", directoryHint: .isDirectory)
        let installer = ClaudeStatuslineInstaller()

        let snapshot = try installer.install(
            configDirectory: root,
            accountID: AccountID("claude-main"),
            label: "Main",
            outputDirectory: output,
            bridgeURL: URL(
                fileURLWithPath: "/Library/PrivilegedHelperTools/mac-tower-claude-bridge")
        )
        #expect(snapshot == output.appending(path: "claude-main.json").standardizedFileURL)
        let installed = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        )
        let installedStatus = try #require(installed["statusLine"] as? [String: Any])
        #expect(
            (installedStatus["command"] as? String)?.hasSuffix("mactower-statusline.sh") == true)
        let wrapper = try String(
            contentsOf: root.appending(path: "mactower-statusline.sh"),
            encoding: .utf8
        )
        #expect(wrapper.contains("mac-tower-claude-bridge"))
        #expect(wrapper.contains("mactower-statusline-original.command"))
        _ = try installer.install(
            configDirectory: root,
            accountID: AccountID("claude-main"),
            label: "Main",
            outputDirectory: output,
            bridgeURL: URL(
                fileURLWithPath: "/Library/PrivilegedHelperTools/mac-tower-claude-bridge")
        )
        let preservedCommand = try String(
            contentsOf: root.appending(path: "mactower-statusline-original.command"),
            encoding: .utf8
        )
        #expect(preservedCommand == "printf old")

        try installer.uninstall(configDirectory: root)
        let restored = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        )
        #expect(restored["theme"] as? String == "dark")
        let restoredStatus = try #require(restored["statusLine"] as? [String: Any])
        #expect(restoredStatus["command"] as? String == "printf old")
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appending(path: "mactower-statusline.sh").path))
    }
}
