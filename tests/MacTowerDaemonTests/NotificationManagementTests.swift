import Foundation
import MacTowerCore
import Testing

@testable import MacTowerDaemon

@Suite("Notification management contract")
struct NotificationManagementTests {
    @Test("History limits and finite channel values are validated while decoding")
    func boundedRequests() throws {
        #expect(throws: NotificationManagementRequestError.invalidHistoryLimit) {
            _ = try NotificationHistoryRequest(limit: 0)
        }
        #expect(throws: Error.self) {
            _ = try JSONDecoder().decode(
                NotificationHistoryRequest.self,
                from: Data(#"{"limit":101}"#.utf8)
            )
        }
        #expect(throws: Error.self) {
            _ = try JSONDecoder().decode(
                TestNotificationChannelRequest.self,
                from: Data(#"{"channel":"shell"}"#.utf8)
            )
        }
        #expect(
            try JSONDecoder().decode(
                AcknowledgeNotificationRequest.self,
                from: Data(
                    #"{"eventID":"550e8400-e29b-41d4-a716-446655440000"}"#.utf8)
            ).eventID.uuidString.lowercased() == "550e8400-e29b-41d4-a716-446655440000"
        )
    }

    @Test("Older status decodes unknown notification health as nil and never contains a token")
    func compatibleStatus() throws {
        let status = DaemonStatus(
            running: true,
            httpEnabled: false,
            mqttEnabled: false,
            configuration: try ServiceConfiguration(),
            accounts: [],
            notificationSummary: sampleSummary
        )
        let encoded = try JSONEncoder().encode(status)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("secret-panel-token"))

        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "notificationSummary")
        let oldData = try JSONSerialization.data(withJSONObject: object)
        #expect(
            try JSONDecoder().decode(DaemonStatus.self, from: oldData).notificationSummary == nil)
    }

    @Test("Handler routes finite notification operations and isolates unavailable service")
    func handlerOperations() async throws {
        let service = FakeNotificationManagementService(summary: sampleSummary)
        let handler = DaemonManagementHandler(
            controller: NotificationManagementControllerStub(),
            power: NotificationPowerStub(),
            notifications: service
        )
        let eventID = UUID()

        _ = try await handler.handle(
            envelope(
                .replaceNotificationConfiguration,
                payload: NotificationConfiguration.disabled
            ))
        _ = try await handler.handle(
            envelope(
                .acknowledgeNotification,
                payload: AcknowledgeNotificationRequest(eventID: eventID)
            ))
        _ = try await handler.handle(
            envelope(
                .notificationHistory,
                payload: try NotificationHistoryRequest(limit: 20)
            ))
        let paired = try JSONDecoder().decode(
            NSPanelPairingStatus.self,
            from: try await handler.handle(envelope(.pairNSPanel))
        )
        #expect(paired == .pressDone)
        #expect(await service.acknowledgedIDs == [eventID])
        #expect(await service.historyLimits == [20])

        let unavailable = DaemonManagementHandler(
            controller: NotificationManagementControllerStub(),
            power: NotificationPowerStub()
        )
        await #expect(throws: NotificationManagementServiceError.unavailable) {
            try await unavailable.handle(envelope(.pairNSPanel))
        }
        let status = try JSONDecoder().decode(
            DaemonStatus.self,
            from: try await unavailable.handle(envelope(.status))
        )
        #expect(status.notificationSummary == nil)
    }

    @Test("Notification management payload is capped independently")
    func payloadCap() async {
        let handler = DaemonManagementHandler(
            controller: NotificationManagementControllerStub(),
            power: NotificationPowerStub(),
            notifications: FakeNotificationManagementService(summary: sampleSummary)
        )
        let request = ManagementEnvelope(
            operation: .replaceNotificationConfiguration,
            payload: Data(repeating: 0, count: 65_537)
        )
        await #expect(throws: Error.self) {
            try await handler.handle(JSONEncoder().encode(request))
        }
    }

    private func envelope(_ operation: ManagementOperation) throws -> Data {
        try JSONEncoder().encode(ManagementEnvelope(operation: operation))
    }

    private func envelope<Payload: Encodable>(
        _ operation: ManagementOperation,
        payload: Payload
    ) throws -> Data {
        try JSONEncoder().encode(
            ManagementEnvelope(
                operation: operation,
                payload: try JSONEncoder().encode(payload)
            ))
    }

    private var sampleSummary: NotificationSummary {
        NotificationSummary(
            engine: NotificationEngineSummary(
                configuration: .disabled,
                knownSources: [],
                activeCriticalCount: 0,
                recentRecords: []
            ),
            mqtt: .disabled,
            mac: .unavailable,
            panel: .disabled,
            panelTokenPresent: true
        )
    }
}

private actor FakeNotificationManagementService: NotificationServiceControlling {
    let value: NotificationSummary
    private(set) var acknowledgedIDs: [UUID] = []
    private(set) var historyLimits: [Int] = []

    init(summary: NotificationSummary) { value = summary }
    func start() async throws {}
    func stop() async {}
    func setMQTTPublisher(_ publisher: (any NotificationMQTTPublishing)?) async {}
    func receiveMQTT(topic: String, payload: Data, retained: Bool, now: Date) async {}
    func registerUserAgent(_ agent: (any NotificationUserAgent)?) async {}
    func unregisterUserAgent(id: UUID) async {}
    func acknowledge(
        eventID: UUID, actor: NotificationAcknowledgementActor, now: Date
    ) async throws { acknowledgedIDs.append(eventID) }
    func replaceConfiguration(_ configuration: NotificationConfiguration) async throws {}
    func configuration() async -> NotificationConfiguration { .disabled }
    func summary() async -> NotificationSummary { value }
    func history(
        limit: Int, before: NotificationHistoryCursor?
    ) async -> NotificationHistoryPage {
        historyLimits.append(limit)
        return NotificationHistoryPage(records: [], nextCursor: nil)
    }
    func pairNSPanel() async throws -> NSPanelPairingStatus { .pressDone }
    func clearNSPanelToken() async throws {}
    func testChannel(_ channel: NotificationTestChannel) async -> NotificationDeliveryState {
        .handedOff
    }
}

private actor NotificationManagementControllerStub: ManagementControlling {
    func status() async -> DaemonStatus {
        DaemonStatus(
            running: true,
            httpEnabled: false,
            mqttEnabled: false,
            configuration: try! ServiceConfiguration(),
            accounts: []
        )
    }
    func replaceConfiguration(_ request: ReplaceConfigurationRequest) async throws {}
    func addDeepSeek(_ request: AddDeepSeekAccountRequest) async throws {}
    func linkClaude(_ request: LinkClaudeProfileRequest) async throws {}
    func startCodexOAuth(_ request: StartCodexOAuthRequest) async throws -> CodexOAuthStart {
        throw ManagementControllerError.invalidRequest
    }
    func cancelCodexOAuth(_ request: CancelCodexOAuthRequest) async {}
    func removeAccount(_ request: RemoveAccountRequest) async throws {}
}

private struct NotificationPowerStub: PowerControlServicing {
    func status() -> PowerControlStatus {
        PowerControlStatus(requestedMode: .normal, persistedMode: .normal, appliedMode: .normal)
    }
    func setMode(_ mode: PowerMode) -> PowerControlStatus {
        PowerControlStatus(requestedMode: mode, persistedMode: mode, appliedMode: mode)
    }
}
