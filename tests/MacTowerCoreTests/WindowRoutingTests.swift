import Foundation
import MacTowerCore
import Testing

@Suite("Window command routing")
struct WindowRoutingTests {
    let displayID = "D364C22E-0BC7-448E-82F4-B8FB12956AE2"

    func snapshot(_ generation: UUID = UUID(), availability: WindowControlAvailability = .ready)
        -> WindowAgentSnapshot
    {
        WindowAgentSnapshot(
            generation: generation,
            displays: [
                WindowDisplay(
                    id: displayID, name: "Test display",
                    frame: .init(x: 0, y: 0, width: 1920, height: 1080),
                    visibleFrame: .init(x: 0, y: 30, width: 1920, height: 1050), isPrimary: true)
            ], availability: availability)
    }

    @Test func disabledByDefaultAndNoRetargetAfterReconnection() async throws {
        let router = WindowCommandRouter()
        let connection = UUID()
        try await router.updateAgent(
            id: connection, snapshot: snapshot(),
            execute: { request, reply in
                reply(.init(requestID: request.id, displayID: request.displayID, code: .success))
            }, cancel: {}, now: 10)
        await router.setBrokerConnected(true)
        let disabled = await router.state(now: 10)
        #expect(!disabled.enabled)
        #expect(await router.move(displayID: displayID, epoch: disabled.epoch, now: 10) == nil)
        await router.setEnabled(true)
        let ready = await router.state(now: 10)
        #expect(
            await router.move(displayID: displayID, epoch: ready.epoch, now: 10)?.code == .success)
        await router.disconnectAgent(id: connection)
        #expect(await router.move(displayID: displayID, epoch: ready.epoch, now: 10) == nil)
    }

    @Test func staleLeaseUnknownSessionAndOldEpochNeverExecute() async throws {
        let router = WindowCommandRouter(enabled: true)
        let connection = UUID()
        let generation = UUID()
        try await router.updateAgent(
            id: connection, snapshot: snapshot(generation),
            execute: { _, _ in
                Issue.record("Rejected command executed")
            }, cancel: {}, now: 10)
        await router.setBrokerConnected(true)
        let before = await router.state(now: 10)
        #expect(await router.move(displayID: displayID, epoch: before.epoch, now: 20) == nil)
        try await router.updateAgent(
            id: connection, snapshot: snapshot(generation, availability: .sessionStateUnknown),
            execute: { _, _ in Issue.record("Locked command executed") }, cancel: {}, now: 20)
        let locked = await router.state(now: 20)
        #expect(await router.move(displayID: displayID, epoch: locked.epoch, now: 20) == nil)
        #expect(locked.epoch != before.epoch)
    }

    @Test func secondLiveAgentCannotReplaceFirst() async throws {
        let router = WindowCommandRouter()
        try await router.updateAgent(
            id: UUID(), snapshot: snapshot(), execute: { _, _ in }, cancel: {}, now: 1)
        await #expect(throws: WindowRoutingError.agentAlreadyConnected) {
            try await router.updateAgent(
                id: UUID(), snapshot: snapshot(), execute: { _, _ in }, cancel: {}, now: 2)
        }
    }

    @Test func missingReplyTimesOutWithoutRetry() async throws {
        let router = WindowCommandRouter(enabled: true, commandTimeout: .milliseconds(20))
        try await router.updateAgent(
            id: UUID(), snapshot: snapshot(), execute: { _, _ in }, cancel: {}, now: 1)
        await router.setBrokerConnected(true)
        let state = await router.state(now: 1)
        let result = await router.move(displayID: displayID, epoch: state.epoch, now: 1)
        #expect(result?.code == .timeout)
    }

    @Test func snapshotRejectsInvalidIdentifiersAndGeometry() throws {
        let bad = WindowAgentSnapshot(
            generation: UUID(),
            displays: [
                .init(
                    id: "../../topic", name: "Display",
                    frame: .init(x: 0, y: 0, width: 0, height: 1),
                    visibleFrame: .init(x: 0, y: 0, width: 1, height: 1), isPrimary: true)
            ], availability: .ready)
        #expect(throws: WindowControlContractError.self) { try bad.validate() }
        let valid = snapshot()
        let first = try #require(valid.displays.first)
        let duplicate = WindowDisplay(
            id: first.id.lowercased(), name: first.name, frame: first.frame,
            visibleFrame: first.visibleFrame, isPrimary: false)
        #expect(throws: WindowControlContractError.self) {
            try WindowAgentSnapshot(
                generation: UUID(), displays: [first, duplicate], availability: .ready
            ).validate()
        }
    }

    @Test func overlappingCommandsAreNotQueuedAndReplyIdentityIsChecked() async throws {
        let router = WindowCommandRouter(enabled: true)
        let (requests, stream) = AsyncStream<WindowMoveRequest>.makeStream()
        let replies = TestWindowReplies()
        try await router.updateAgent(
            id: UUID(), snapshot: snapshot(),
            execute: { request, reply in
                replies.save(reply)
                stream.yield(request)
            }, cancel: {}, now: 1)
        await router.setBrokerConnected(true)
        let epoch = await router.state(now: 1).epoch
        let pending = Task { await router.move(displayID: displayID, epoch: epoch, now: 1) }
        var iterator = requests.makeAsyncIterator()
        let request = try #require(await iterator.next())
        #expect(request.epoch == epoch)
        #expect(await router.move(displayID: displayID, epoch: epoch, now: 1)?.code == .busy)
        replies.complete(.init(requestID: UUID(), displayID: displayID, code: .success))
        #expect(await pending.value?.code == .invalidCommand)
        stream.finish()
    }

    @Test func busyHeartbeatKeepsEpochButBrokerAndOptInChangesInvalidateIt() async throws {
        let router = WindowCommandRouter(enabled: true)
        let connection = UUID()
        let generation = UUID()
        try await router.updateAgent(
            id: connection, snapshot: snapshot(generation), execute: { _, _ in }, cancel: {}, now: 1
        )
        await router.setBrokerConnected(true)
        let before = await router.state(now: 1)
        try await router.updateAgent(
            id: connection, snapshot: snapshot(generation, availability: .busy),
            execute: { _, _ in }, cancel: {}, now: 2)
        #expect(await router.state(now: 2).epoch == before.epoch)
        await router.setBrokerConnected(false)
        let after = await router.state(now: 2)
        #expect(after.epoch != before.epoch)
        await router.setEnabled(false)
        #expect(await router.state(now: 2).epoch != after.epoch)
    }

    @Test func disconnectedAgentKeepsDisplayMetadataButNeverAuthority() async throws {
        let router = WindowCommandRouter(enabled: true)
        let connection = UUID()
        try await router.updateAgent(
            id: connection, snapshot: snapshot(), execute: { _, _ in }, cancel: {}, now: 1)
        await router.setBrokerConnected(true)
        await router.disconnectAgent(id: connection)
        let state = await router.state(now: 2)
        #expect(state.snapshot?.displays.first?.id == displayID)
        #expect(state.snapshot?.availability == .unavailable)
        #expect(await router.move(displayID: displayID, epoch: state.epoch, now: 2) == nil)
    }

    @Test func workingAreaIsRefreshedWithoutInvalidatingPhysicalTopology() async throws {
        let router = WindowCommandRouter(enabled: true)
        let connection = UUID()
        let initial = snapshot()
        try await router.updateAgent(
            id: connection, snapshot: initial, execute: { _, _ in }, cancel: {}, now: 1)
        let epoch = await router.state(now: 1).epoch
        let first = try #require(initial.displays.first)
        let resizedWorkArea = WindowDisplay(
            id: first.id, name: "Renamed", frame: first.frame,
            visibleFrame: .init(x: 0, y: 0, width: 1920, height: 1080), isPrimary: true)
        let changed = WindowAgentSnapshot(
            generation: initial.generation, displays: [resizedWorkArea], availability: .ready)
        try await router.updateAgent(
            id: connection, snapshot: changed, execute: { _, _ in }, cancel: {}, now: 2)
        let refreshed = await router.state(now: 2)
        #expect(refreshed.epoch == epoch)
        #expect(refreshed.snapshot == changed)
        let movedScreen = WindowDisplay(
            id: first.id, name: first.name,
            frame: .init(x: 100, y: 0, width: 1920, height: 1080), visibleFrame: first.visibleFrame,
            isPrimary: true)
        try await router.updateAgent(
            id: connection,
            snapshot: .init(
                generation: initial.generation, displays: [movedScreen], availability: .ready),
            execute: { _, _ in }, cancel: {}, now: 3)
        #expect(await router.state(now: 3).epoch != epoch)
    }
}

private final class TestWindowReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: (@Sendable (WindowMoveResult) -> Void)?

    func save(_ reply: @escaping @Sendable (WindowMoveResult) -> Void) {
        lock.lock()
        self.reply = reply
        lock.unlock()
    }

    func complete(_ result: WindowMoveResult) {
        lock.lock()
        let current = reply
        reply = nil
        lock.unlock()
        current?(result)
    }
}
