import Foundation
import Testing

@testable import MacTowerCore

@Suite("Power control contract")
struct PowerControlContractTests {
    @Test func modesAreFiniteAndCodable() throws {
        #expect(PowerMode.allCases == [.normal, .keepMacAwake, .keepMacAndDisplaysAwake])
        #expect(PowerMode.normal.rawValue == "normal")
        #expect(PowerMode.keepMacAwake.rawValue == "keep_mac_awake")
        #expect(PowerMode.keepMacAndDisplaysAwake.rawValue == "keep_mac_and_displays_awake")
        for mode in PowerMode.allCases {
            #expect(
                try JSONDecoder().decode(PowerMode.self, from: JSONEncoder().encode(mode))
                    == mode)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PowerMode.self, from: Data(#""future-mode""#.utf8))
        }
    }

    @Test func statusSeparatesRequestedPersistedAndApplied() throws {
        let value = PowerControlStatus(
            requestedMode: .normal,
            persistedMode: .keepMacAwake,
            appliedMode: .normal,
            issue: .persistenceFailed)
        #expect(
            try JSONDecoder().decode(
                PowerControlStatus.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func setModeOperationIsFinite() throws {
        let request = SetPowerModeRequest(mode: .keepMacAndDisplaysAwake)
        let envelope = ManagementEnvelope(
            operation: .setPowerMode, payload: try JSONEncoder().encode(request))
        #expect(
            try JSONDecoder().decode(
                ManagementEnvelope.self, from: JSONEncoder().encode(envelope)
            ).operation == .setPowerMode)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ManagementEnvelope.self,
                from: Data(#"{"operation":"run_command","payload":null}"#.utf8))
        }
    }

    @Test func daemonStatusDecodesMissingPowerControlAsUnknown() throws {
        let legacy = DaemonStatus(
            running: true,
            httpEnabled: false,
            mqttEnabled: false,
            configuration: try ServiceConfiguration(),
            accounts: [])
        let status = try JSONDecoder().decode(
            DaemonStatus.self, from: JSONEncoder().encode(legacy))
        #expect(status.powerControl == nil)
    }
}
