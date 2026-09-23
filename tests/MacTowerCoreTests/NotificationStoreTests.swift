import Darwin
import Foundation
import Testing

@testable import MacTowerCore

@Suite("Notification private store")
struct NotificationStoreTests {
    @Test("Missing state returns a disabled empty version")
    func missingStateIsEmpty() throws {
        try withTemporaryRoot { root in
            let store = try FileNotificationStateStore(root: root)
            let state = try store.load()

            #expect(state == .empty)
            #expect(state.version == 1)
            #expect(state.configuration == .disabled)
            #expect(state.knownSources.isEmpty)
            #expect(state.records.isEmpty)

            let rootMode = try permissions(at: root)
            #expect(rootMode == 0o700)
        }
    }

    @Test("Round trip is sorted, epoch based, private, and isolated")
    func roundTripIsPrivateAndIsolated() throws {
        try withTemporaryRoot { root in
            let privateStore = try PrivateFileStore(root: root)
            let adjacent: [String: Data] = [
                "service.json": Data("service".utf8),
                "power-control.json": Data("power".utf8),
                "mqtt-password": Data("password".utf8),
                "accounts.json": Data("accounts".utf8),
            ]
            for (name, data) in adjacent {
                try privateStore.write(data, named: name)
            }

            let source = try NotificationSourceID(validating: "ups.main")
            let timestamp = Date(timeIntervalSince1970: 1_790_102_100)
            let event = NotificationEvent(
                eventID: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
                sourceID: source,
                severity: .critical,
                title: "UPS",
                message: "On battery",
                createdAt: timestamp
            )
            let record = NotificationRecord(
                event: event,
                firstSeenAt: timestamp,
                lastSeenAt: timestamp,
                isActive: true,
                deliveryPlan: NotificationDeliveryPlan(channels: [.mqtt]),
                deliveries: [.mqtt: NotificationChannelDelivery(state: .queued)]
            )
            let state = NotificationPersistentState(
                configuration: .disabled,
                knownSources: [source],
                records: [record]
            )
            let store = try FileNotificationStateStore(root: root)

            try store.save(state)

            #expect(try store.load() == state)
            let stateURL = root.appending(path: FileNotificationStateStore.fileName)
            #expect(try permissions(at: stateURL) == 0o600)
            let raw = try #require(
                try privateStore.read(named: FileNotificationStateStore.fileName))
            let text = String(decoding: raw, as: UTF8.self)
            #expect(text.hasPrefix(#"{"configuration":"#))
            #expect(text.contains(#""firstSeenAt":1790102100"#))
            for (name, expected) in adjacent {
                #expect(try privateStore.read(named: name) == expected)
            }
        }
    }

    @Test("A notification state symlink is refused for reads and writes")
    func symlinkIsRefused() throws {
        try withTemporaryRoot { root in
            _ = try PrivateFileStore(root: root)
            let outside = root.deletingLastPathComponent().appending(
                path: "outside-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: outside) }
            try Data("outside".utf8).write(to: outside)
            let link = root.appending(path: FileNotificationStateStore.fileName)
            #expect(symlink(outside.path, link.path) == 0)
            let store = try FileNotificationStateStore(root: root)

            #expect(throws: NotificationStoreError.storageFailure) {
                try store.load()
            }
            #expect(throws: NotificationStoreError.storageFailure) {
                try store.save(.empty)
            }
            #expect(try Data(contentsOf: outside) == Data("outside".utf8))
        }
    }

    @Test("Malformed and future versions are distinct and never rewritten")
    func invalidStateIsNotRewritten() throws {
        try withTemporaryRoot { root in
            let privateStore = try PrivateFileStore(root: root)
            let store = try FileNotificationStateStore(root: root)

            let malformed = Data("not-json".utf8)
            try privateStore.write(malformed, named: FileNotificationStateStore.fileName)
            #expect(throws: NotificationStoreError.malformedState) {
                try store.load()
            }
            #expect(try privateStore.read(named: FileNotificationStateStore.fileName) == malformed)

            let future = Data(#"{"version":2}"#.utf8)
            try privateStore.write(future, named: FileNotificationStateStore.fileName)
            #expect(throws: NotificationStoreError.unsupportedVersion) {
                try store.load()
            }
            #expect(try privateStore.read(named: FileNotificationStateStore.fileName) == future)
        }
    }

    @Test("Save rejects a noncurrent version without replacing current bytes")
    func invalidSaveDoesNotReplaceState() throws {
        try withTemporaryRoot { root in
            let privateStore = try PrivateFileStore(root: root)
            let store = try FileNotificationStateStore(root: root)
            try store.save(.empty)
            let original = try #require(
                try privateStore.read(named: FileNotificationStateStore.fileName))
            var invalid = NotificationPersistentState.empty
            invalid.version = 2

            #expect(throws: NotificationStoreError.unsupportedVersion) {
                try store.save(invalid)
            }
            #expect(
                try privateStore.read(named: FileNotificationStateStore.fileName) == original)
        }
    }

    @Test("Decoded configuration must pass current validation")
    func invalidPersistedConfigurationIsRejected() throws {
        try withTemporaryRoot { root in
            let privateStore = try PrivateFileStore(root: root)
            let invalid = NotificationPersistentState(
                configuration: NotificationConfiguration(
                    panel: NSPanelConfiguration(host: "8.8.8.8")),
                knownSources: [],
                records: []
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            try privateStore.write(
                try encoder.encode(invalid), named: FileNotificationStateStore.fileName)

            #expect(throws: NotificationStoreError.invalidConfiguration) {
                try FileNotificationStateStore(root: root).load()
            }
        }
    }

    private func withTemporaryRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "mac-tower-notification-store-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}
