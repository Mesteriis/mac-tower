import MacTowerCore
import Testing

@testable import MacTowerApp

@Suite("PowerModePresentationTests")
@MainActor
struct PowerModePresentationTests {
    @Test func labelsExplainEveryModeAndPersistenceFailure() {
        #expect(PowerMode.normal.displayName == "Normal")
        #expect(PowerMode.keepMacAwake.displayName == "Keep Mac awake")
        #expect(PowerMode.keepMacAndDisplaysAwake.displayName == "Keep Mac and displays awake")
        #expect(PowerControlIssue.persistenceFailed.explanation.contains("restart"))
        for issue in [
            PowerControlIssue.invalidSettings,
            .persistenceFailed,
            .assertionCreateFailed,
            .assertionReleaseFailed,
        ] {
            #expect(!issue.explanation.isEmpty)
        }
    }

    @Test func confirmedResponseReplacesStatusForOnlyThePendingRequest() {
        let original = status(.normal)
        let replacement = status(.keepMacAwake)
        var state = PowerModePresentationState(confirmedStatus: original)
        let request = state.begin(.keepMacAwake)
        #expect(state.pendingMode == .keepMacAwake)
        let confirmed = state.confirm(replacement, requestID: request)
        #expect(confirmed)
        #expect(state.confirmedStatus == replacement)
        #expect(state.pendingMode == nil)
        #expect(state.errorMessage == nil)
    }

    @Test func failureKeepsConfirmationAndIgnoresLateReplyWithoutRetry() {
        let original = status(.normal)
        var state = PowerModePresentationState(confirmedStatus: original)
        let request = state.begin(.keepMacAndDisplaysAwake)
        let failed = state.fail(requestID: request, message: "Timed out")
        #expect(failed)
        #expect(state.confirmedStatus == original)
        #expect(state.pendingMode == nil)
        #expect(state.errorMessage == "Timed out")
        state.observe(original)
        #expect(state.errorMessage == "Timed out")
        let acceptedLateReply = state.confirm(
            status(.keepMacAndDisplaysAwake), requestID: request)
        #expect(!acceptedLateReply)
        #expect(state.confirmedStatus == original)
    }

    private func status(_ mode: PowerMode) -> PowerControlStatus {
        PowerControlStatus(requestedMode: mode, persistedMode: mode, appliedMode: mode)
    }
}
