import Darwin
import Foundation
import Testing

@testable import MacTowerCore

@Suite("Service configuration and collection core")
struct ServiceCoreTests {
    @Test("Polling interval is bounded and network publishing defaults off")
    func pollingConfiguration() throws {
        #expect(throws: ServiceConfigurationError.self) {
            try ServiceConfiguration(pollIntervalSeconds: 59)
        }

        let configuration = try ServiceConfiguration(pollIntervalSeconds: 300)
        #expect(!configuration.http.enabled)
        #expect(!configuration.mqtt.enabled)
        #expect(configuration.pollIntervalSeconds == 300)
        #expect(configuration.staleAfterSeconds == 900)
    }

    @Test("IPv4 CIDR contains only addresses inside its prefix")
    func cidrValidation() throws {
        let lan = try IPv4CIDR("192.168.50.0/24")
        #expect(lan.contains("192.168.50.1"))
        #expect(lan.contains("192.168.50.255"))
        #expect(!lan.contains("192.168.51.1"))
        #expect(!lan.contains("2001:db8::1"))
        #expect(throws: ServiceConfigurationError.self) {
            try IPv4CIDR("192.168.1.0/33")
        }
    }

    @Test("Account directories cannot escape the managed root")
    func managedAccountPath() throws {
        let root = URL(fileURLWithPath: "/Library/Application Support/MacTower/codex")
        let paths = ManagedAccountPaths(root: root)

        #expect(
            try paths.directory(for: AccountID("personal")).path
                == root.appending(path: "personal").path)
        #expect(throws: ServiceConfigurationError.self) {
            try paths.directory(for: AccountID("../escape"))
        }
        #expect(throws: ServiceConfigurationError.self) {
            try paths.directory(for: AccountID("nested/profile"))
        }
    }

    @Test("A failed refresh preserves the last successful snapshot")
    func staleOnFailure() async {
        let store = SnapshotStore()
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = AccountSnapshot(
            id: AccountID("deepseek-main"),
            provider: .deepSeek,
            label: "Main",
            status: .available,
            source: .deepSeekAPI,
            observedAt: observedAt
        )

        await store.recordSuccess(snapshot, attemptedAt: observedAt)
        await store.recordFailure(
            accountID: snapshot.id,
            attemptedAt: observedAt.addingTimeInterval(60),
            reason: .transport
        )

        let stored = await store.entry(for: snapshot.id)
        #expect(stored?.snapshot == snapshot)
        #expect(stored?.lastAttemptAt == observedAt.addingTimeInterval(60))
        #expect(stored?.lastFailure == .transport)
    }

    @Test("Snapshot persistence uses a regular private file")
    func privateSnapshotPersistence() throws {
        let temporary = FileManager.default.temporaryDirectory.appending(
            path: "mac-tower-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let storage = try PrivateFileStore(root: temporary)
        let data = Data(#"{"ok":true}"#.utf8)
        try storage.write(data, named: "snapshot.json")

        #expect(try storage.read(named: "snapshot.json") == data)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: temporary.appending(path: "snapshot.json").path)
        let mode = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o600)
        #expect(throws: PrivateFileStoreError.self) {
            try storage.write(data, named: "../outside")
        }
    }

    @Test("Codex App Server frames only finite account operations")
    func codexRPCFrames() throws {
        let factory = CodexAppServerRequestFactory()
        let initialize = try factory.initialize(id: 1)
        let rateLimits = try factory.rateLimits(id: 2)
        let login = try factory.startChatGPTLogin(id: 3)

        #expect(initialize.last == 0x0A)
        #expect(String(decoding: initialize, as: UTF8.self).contains(#""method":"initialize""#))
        #expect(
            String(decoding: rateLimits, as: UTF8.self).contains(
                #""method":"account/rateLimits/read""#))
        #expect(String(decoding: login, as: UTF8.self).contains(#""type":"chatgpt""#))
        #expect(!String(decoding: login, as: UTF8.self).contains("refreshToken"))
    }

    @Test("Repeated Claude statusline values retain their original observation time")
    func repeatedClaudeStatusline() throws {
        var telemetry = ClaudeTelemetryState(
            accountID: AccountID("claude-personal"), label: "Personal")
        let firstTime = Date(timeIntervalSince1970: 1_800_000_000)
        let secondTime = firstTime.addingTimeInterval(120)
        let payload = Data(
            #"{"transcript_path":"/private/path","rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1800003600}}}"#
                .utf8
        )

        let first = try telemetry.ingest(payload, receivedAt: firstTime)
        let second = try telemetry.ingest(payload, receivedAt: secondTime)

        #expect(first.observedAt == firstTime)
        #expect(second.observedAt == firstTime)
        let encoded = try PublicSnapshotEncoder().encode([second])
        #expect(!String(decoding: encoded, as: UTF8.self).contains("private/path"))
    }

    @Test("DeepSeek request builder keeps the secret out of its description")
    func deepSeekRequest() throws {
        let request = try DeepSeekRequestBuilder().balanceRequest(apiKey: "test-secret")
        #expect(request.url?.absoluteString == "https://api.deepseek.com/user/balance")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
        #expect(!DeepSeekRequestBuilder().redactedDescription(of: request).contains("test-secret"))
    }

    @Test("Polling retries back off without exceeding the normal interval")
    func pollingBackoff() {
        let policy = PollPolicy(intervalSeconds: 300, retryBaseSeconds: 5)
        #expect(policy.delayAfterSuccess == 300)
        #expect(policy.delay(afterConsecutiveFailures: 1) == 5)
        #expect(policy.delay(afterConsecutiveFailures: 2) == 10)
        #expect(policy.delay(afterConsecutiveFailures: 7) == 300)
    }

    @Test("Codex process configuration pins an absolute binary and managed home")
    func codexProcessConfiguration() throws {
        let root = URL(fileURLWithPath: "/Library/Application Support/MacTower/codex")
        let configuration = try CodexAppServerProcessConfiguration(
            binaryURL: URL(fileURLWithPath: "/Library/PrivilegedHelperTools/mac-tower-codex"),
            homeURL: root.appending(path: "personal"),
            managedAccountsRoot: root
        )

        #expect(configuration.environment["CODEX_HOME"] == root.appending(path: "personal").path)
        #expect(configuration.arguments == ["app-server"])
        #expect(throws: CodexAppServerProcessError.self) {
            try CodexAppServerProcessConfiguration(
                binaryURL: URL(
                    fileURLWithPath: "relative-codex", relativeTo: URL(fileURLWithPath: "/tmp")),
                homeURL: URL(fileURLWithPath: "/tmp/escape"),
                managedAccountsRoot: root
            )
        }
    }

    @Test("Codex response parser separates results, errors, and notifications")
    func codexResponseParsing() throws {
        let parser = CodexAppServerMessageParser()
        let result = try parser.parse(
            Data(#"{"id":6,"result":{"rateLimits":{"limitId":"codex"}}}"#.utf8))
        let notification = try parser.parse(
            Data(#"{"method":"account/rateLimits/updated","params":{"rateLimits":{}}}"#.utf8))
        let error = try parser.parse(
            Data(#"{"id":7,"error":{"code":-32600,"message":"Invalid request"}}"#.utf8))

        #expect(result.id == 6)
        #expect(result.result != nil)
        #expect(notification.method == "account/rateLimits/updated")
        #expect(notification.params != nil)
        #expect(error.id == 7)
        #expect(error.error?.code == -32600)
    }

    @Test("Claude bridge accepts only an explicit account and output directory")
    func claudeBridgeCommand() throws {
        let command = try ClaudeBridgeCommand.parse([
            "--account-id", "claude-personal",
            "--label", "Personal",
            "--output-directory", "/Users/person/Library/Application Support/MacTower/claude",
        ])
        #expect(command.accountID == AccountID("claude-personal"))
        #expect(command.outputDirectory.isFileURL)
        #expect(throws: ClaudeBridgeCommandError.self) {
            try ClaudeBridgeCommand.parse([
                "--account-id", "../escape",
                "--label", "Bad",
                "--output-directory", "relative/path",
            ])
        }
    }

    @Test("Codex rate-limit result is converted without exposing unrelated fields")
    func codexResultConversion() throws {
        let message = try CodexAppServerMessageParser().parse(
            Data(
                #"{"id":4,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":1800003600},"secondary":null,"rateLimitReachedType":null},"privateField":"discard-me"}}"#
                    .utf8
            )
        )
        let snapshot = try CodexRateLimitsResultDecoder().snapshot(
            from: message,
            accountID: AccountID("codex-main"),
            label: "Main",
            observedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(snapshot.quotas.first?.usedPercent == 40)
        #expect(
            !String(decoding: try PublicSnapshotEncoder().encode([snapshot]), as: UTF8.self)
                .contains("discard-me"))
    }
}
