import Foundation
import MacTowerCore
import Testing

@testable import MacTowerDaemon

@Suite("PowerControlLifecycleTests")
struct PowerControlLifecycleTests {
    @Test func statusComposesPowerStateWithoutChangingManagementFields() async throws {
        let base = DaemonStatus(
            running: true,
            httpEnabled: true,
            mqttEnabled: false,
            configuration: try ServiceConfiguration(),
            accounts: [try AccountRegistration.deepSeek(id: AccountID("deepseek"), label: "DS")],
            activeCodexOAuthAccountID: AccountID("codex"))
        let powerStatus = PowerControlStatus(
            requestedMode: .keepMacAwake,
            persistedMode: .keepMacAwake,
            appliedMode: .keepMacAwake)
        let handler = DaemonManagementHandler(
            controller: StubManagementController(status: base),
            power: StubPowerController(status: powerStatus))

        let data = try await handler.handle(
            JSONEncoder().encode(ManagementEnvelope(operation: .status)))
        let result = try JSONDecoder().decode(DaemonStatus.self, from: data)
        #expect(result.running == base.running)
        #expect(result.httpEnabled == base.httpEnabled)
        #expect(result.mqttEnabled == base.mqttEnabled)
        #expect(result.accounts.map(\.id) == base.accounts.map(\.id))
        #expect(result.activeCodexOAuthAccountID == base.activeCodexOAuthAccountID)
        #expect(result.powerControl == powerStatus)
    }

    @Test func setModeAcceptsOnlyOneBoundedFinitePayload() async throws {
        let power = StubPowerController(
            status: PowerControlStatus(
                requestedMode: .normal, persistedMode: .normal, appliedMode: .normal))
        let handler = DaemonManagementHandler(
            controller: StubManagementController(status: try baseStatus()), power: power)
        let request = ManagementEnvelope(
            operation: .setPowerMode,
            payload: try JSONEncoder().encode(SetPowerModeRequest(mode: .keepMacAwake)))
        let data = try await handler.handle(JSONEncoder().encode(request))
        #expect(
            try JSONDecoder().decode(PowerControlStatus.self, from: data).requestedMode
                == .keepMacAwake)
        #expect(power.setModes == [.keepMacAwake])

        await #expect(throws: Error.self) {
            try await handler.handle(
                JSONEncoder().encode(ManagementEnvelope(operation: .setPowerMode)))
        }
        await #expect(throws: Error.self) {
            try await handler.handle(
                JSONEncoder().encode(
                    ManagementEnvelope(
                        operation: .setPowerMode,
                        payload: Data(#"{"mode":"future"}"#.utf8))))
        }
        await #expect(throws: Error.self) {
            try await handler.handle(Data(repeating: 0, count: 1_048_577))
        }
        #expect(power.setModes == [.keepMacAwake])
    }

    @Test func lifecycleStopsPowerBeforeNetwork() async {
        let recorder = StopRecorder()
        let lifecycle = DaemonLifecycle(
            power: RecordingPowerStop(recorder: recorder),
            network: RecordingNetworkStop(recorder: recorder))
        await lifecycle.stop()
        #expect(await recorder.values == ["power", "network"])
    }

    private func baseStatus() throws -> DaemonStatus {
        DaemonStatus(
            running: true,
            httpEnabled: false,
            mqttEnabled: false,
            configuration: try ServiceConfiguration(),
            accounts: [])
    }
}

private final class StubPowerController: PowerControlServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var value: PowerControlStatus
    private(set) var setModes: [PowerMode] = []

    init(status: PowerControlStatus) {
        value = status
    }

    func status() -> PowerControlStatus {
        lock.withLock { value }
    }

    func setMode(_ mode: PowerMode) -> PowerControlStatus {
        lock.withLock {
            setModes.append(mode)
            value = PowerControlStatus(
                requestedMode: mode, persistedMode: mode, appliedMode: mode)
            return value
        }
    }

    func stop() -> PowerControlStatus {
        lock.withLock {
            value = PowerControlStatus(
                requestedMode: value.requestedMode,
                persistedMode: value.persistedMode,
                appliedMode: .normal)
            return value
        }
    }
}

private actor StubManagementController: ManagementControlling {
    let value: DaemonStatus

    init(status: DaemonStatus) { value = status }
    func status() async -> DaemonStatus { value }
    func replaceConfiguration(_ request: ReplaceConfigurationRequest) throws {}
    func addDeepSeek(_ request: AddDeepSeekAccountRequest) async throws {}
    func linkClaude(_ request: LinkClaudeProfileRequest) async throws {}
    func startCodexOAuth(_ request: StartCodexOAuthRequest) async throws -> CodexOAuthStart {
        throw ManagementControllerError.invalidRequest
    }
    func cancelCodexOAuth(_ request: CancelCodexOAuthRequest) async {}
    func removeAccount(_ request: RemoveAccountRequest) async throws {}
}

private actor StopRecorder {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private struct RecordingPowerStop: PowerStopping {
    let recorder: StopRecorder
    func stopPower() async { await recorder.append("power") }
}

private struct RecordingNetworkStop: NetworkStopping {
    let recorder: StopRecorder
    func stop() async { await recorder.append("network") }
}
