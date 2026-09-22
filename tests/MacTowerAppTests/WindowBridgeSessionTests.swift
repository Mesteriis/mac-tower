import Foundation
import MacTowerCore
import Testing

@testable import MacTowerApp

@Suite("GUI window command admission")
struct WindowBridgeSessionTests {
    @Test("A connection alone grants no control, and opt-in requires an acknowledgement")
    func requiresAcknowledgement() {
        var session = WindowBridgeSession()
        let connection = UUID()
        let epoch = UUID()
        let request = command(epoch: epoch)
        session.connect(connection)
        #expect(session.admit(request, connectionID: connection, isBusy: false) == .unavailable)
        session.beginPreferenceChange(enabled: true)
        #expect(session.admit(request, connectionID: connection, isBusy: false) == .unavailable)
        session.acknowledge(
            .init(enabled: true, epoch: epoch), connectionID: connection, revision: session.revision
        )
        #expect(session.admit(request, connectionID: connection, isBusy: false) == nil)
    }

    @Test("Disable revokes immediately and an old heartbeat cannot restore consent")
    func staleHeartbeatAfterDisable() {
        var (session, connection, epoch) = readySession()
        let oldRevision = session.revision
        session.beginPreferenceChange(enabled: false)
        #expect(!session.remoteEnabled)
        #expect(session.commandEpoch == nil)
        let accepted = session.acknowledge(
            .init(enabled: true, epoch: epoch), connectionID: connection, revision: oldRevision)
        #expect(!accepted)
        #expect(
            session.admit(command(epoch: epoch), connectionID: connection, isBusy: false)
                == .unavailable)
    }

    @Test("Cancelled epochs cannot run after a later heartbeat enables the same connection")
    func staleEpochAfterCancellation() {
        var (session, connection, oldEpoch) = readySession()
        let oldRevision = session.revision
        session.cancelRemoteCommands()
        #expect(session.commandEpoch == nil)
        let accepted = session.acknowledge(
            .init(enabled: true, epoch: oldEpoch), connectionID: connection,
            revision: oldRevision)
        #expect(!accepted)
        let newEpoch = UUID()
        session.acknowledge(
            .init(enabled: true, epoch: newEpoch), connectionID: connection,
            revision: session.revision)
        #expect(
            session.admit(command(epoch: oldEpoch), connectionID: connection, isBusy: false)
                == .unavailable)
        #expect(
            session.admit(command(epoch: newEpoch), connectionID: connection, isBusy: false) == nil)
    }

    @Test("Disconnected and replaced connection callbacks never regain control")
    func replacedConnection() {
        var (session, previousConnection, epoch) = readySession()
        let oldRevision = session.revision
        session.disconnect()
        #expect(!session.isConnected && !session.remoteEnabled && session.commandEpoch == nil)
        let currentConnection = UUID()
        session.connect(currentConnection)
        let accepted = session.acknowledge(
            .init(enabled: true, epoch: epoch), connectionID: previousConnection,
            revision: oldRevision)
        #expect(!accepted)
        session.acknowledge(
            .init(enabled: true, epoch: epoch), connectionID: currentConnection,
            revision: session.revision)
        #expect(
            session.admit(command(epoch: epoch), connectionID: previousConnection, isBusy: false)
                == .unavailable)
    }

    @Test("Overlapping, replayed, and malformed commands are rejected")
    func commandRejection() {
        var (session, connection, epoch) = readySession()
        let request = command(epoch: epoch)
        #expect(session.admit(request, connectionID: connection, isBusy: true) == .busy)
        #expect(session.admit(request, connectionID: connection, isBusy: false) == nil)
        #expect(session.admit(request, connectionID: connection, isBusy: false) == .invalidCommand)
        let malformed = WindowMoveRequest(
            displayID: "display-index-0", generation: UUID(), epoch: epoch)
        #expect(
            session.admit(malformed, connectionID: connection, isBusy: false) == .invalidCommand)
    }

    private func command(epoch: UUID) -> WindowMoveRequest {
        WindowMoveRequest(displayID: UUID().uuidString, generation: UUID(), epoch: epoch)
    }

    private func readySession() -> (WindowBridgeSession, UUID, UUID) {
        var session = WindowBridgeSession()
        let connection = UUID()
        let epoch = UUID()
        session.connect(connection)
        session.acknowledge(
            .init(enabled: true, epoch: epoch), connectionID: connection, revision: session.revision
        )
        return (session, connection, epoch)
    }
}
