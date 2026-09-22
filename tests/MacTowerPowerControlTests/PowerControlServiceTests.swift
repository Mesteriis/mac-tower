import Foundation
import MacTowerCore
import Testing

@testable import MacTowerPowerControl

@Suite("PowerControlServiceTests")
struct PowerControlServiceTests {
    @Test func allDistinctTransitionsUseTheMinimalOrderedOperations() throws {
        let cases: [(PowerMode, PowerMode, [BackendEvent])] = [
            (.normal, .keepMacAwake, [.acquire(.preventUserIdleSystemSleep)]),
            (.normal, .keepMacAndDisplaysAwake, [.acquire(.preventUserIdleDisplaySleep)]),
            (.keepMacAwake, .normal, [.release(.preventUserIdleSystemSleep)]),
            (
                .keepMacAwake, .keepMacAndDisplaysAwake,
                [
                    .acquire(.preventUserIdleDisplaySleep),
                    .release(.preventUserIdleSystemSleep),
                ]
            ),
            (.keepMacAndDisplaysAwake, .normal, [.release(.preventUserIdleDisplaySleep)]),
            (
                .keepMacAndDisplaysAwake, .keepMacAwake,
                [
                    .acquire(.preventUserIdleSystemSleep),
                    .release(.preventUserIdleDisplaySleep),
                ]
            ),
        ]

        for (source, destination, expectedEvents) in cases {
            let fixture = Fixture(initial: source)
            fixture.backend.clearEvents()
            let status = fixture.service.setMode(destination)
            #expect(fixture.backend.events == expectedEvents)
            #expect(status.requestedMode == destination)
            #expect(status.persistedMode == destination)
            #expect(status.appliedMode == destination)
            #expect(status.issue == nil)
            #expect(fixture.backend.activeKinds == Set(kind(destination).map { [$0] } ?? []))
        }
    }

    @Test func selectingTheAppliedModeIsIdempotent() {
        for mode in PowerMode.allCases {
            let fixture = Fixture(initial: mode)
            fixture.backend.clearEvents()
            let status = fixture.service.setMode(mode)
            #expect(fixture.backend.events.isEmpty)
            #expect(fixture.store.savedModes.isEmpty)
            #expect(status.issue == nil)
            #expect(status.appliedMode == mode)
        }
    }

    @Test func startupRestoresThePersistedMode() {
        let fixture = Fixture(initial: .keepMacAndDisplaysAwake)
        #expect(fixture.backend.events == [.acquire(.preventUserIdleDisplaySleep)])
        #expect(fixture.service.status().requestedMode == .keepMacAndDisplaysAwake)
        #expect(fixture.service.status().appliedMode == .keepMacAndDisplaysAwake)
    }

    @Test func loadFailureFailsOpenWithoutOverwritingSettings() {
        let store = MemoryModeStore(initial: .keepMacAwake)
        store.failLoad = true
        let backend = RecordingBackend()
        let service = PowerControlService(store: store, backend: backend)
        #expect(
            service.status()
                == PowerControlStatus(
                    requestedMode: .normal, persistedMode: nil, appliedMode: .normal,
                    issue: .invalidSettings))
        #expect(store.savedModes.isEmpty)
        #expect(backend.events.isEmpty)
    }

    @Test func nonNormalSaveFailureDoesNotChangeAssertionsOrRequestedMode() {
        let fixture = Fixture(initial: .normal)
        fixture.store.failSave = true
        let status = fixture.service.setMode(.keepMacAwake)
        #expect(status.requestedMode == .normal)
        #expect(status.persistedMode == .normal)
        #expect(status.appliedMode == .normal)
        #expect(status.issue == .persistenceFailed)
        #expect(fixture.backend.events.isEmpty)
    }

    @Test func normalSaveFailureStillReleasesEveryAssertion() {
        let fixture = Fixture(initial: .keepMacAwake)
        fixture.backend.clearEvents()
        fixture.store.failSave = true
        let status = fixture.service.setMode(.normal)
        #expect(status.requestedMode == .normal)
        #expect(status.persistedMode == .keepMacAwake)
        #expect(status.appliedMode == .normal)
        #expect(status.issue == .persistenceFailed)
        #expect(fixture.backend.events == [.release(.preventUserIdleSystemSleep)])
        #expect(fixture.backend.activeKinds.isEmpty)
    }

    @Test func acquireFailureKeepsOldAssertionAndCanBeRetried() {
        let fixture = Fixture(initial: .normal)
        fixture.backend.failAcquireKinds = [.preventUserIdleSystemSleep]
        let failed = fixture.service.setMode(.keepMacAwake)
        #expect(failed.requestedMode == .keepMacAwake)
        #expect(failed.persistedMode == .keepMacAwake)
        #expect(failed.appliedMode == .normal)
        #expect(failed.issue == .assertionCreateFailed)

        fixture.backend.failAcquireKinds = []
        let recovered = fixture.service.setMode(.keepMacAwake)
        #expect(recovered.appliedMode == .keepMacAwake)
        #expect(recovered.issue == nil)
        #expect(fixture.backend.activeKinds == [.preventUserIdleSystemSleep])
    }

    @Test func releaseFailureKeepsEveryLiveHandleAndCanBeRetriedWithoutDuplicateAcquire() {
        let fixture = Fixture(initial: .keepMacAwake)
        fixture.backend.clearEvents()
        fixture.backend.failReleaseKinds = [.preventUserIdleSystemSleep]
        let failed = fixture.service.setMode(.keepMacAndDisplaysAwake)
        #expect(
            fixture.backend.events == [
                .acquire(.preventUserIdleDisplaySleep),
                .release(.preventUserIdleSystemSleep),
            ])
        #expect(fixture.backend.activeKinds.count == 2)
        #expect(failed.appliedMode == .keepMacAndDisplaysAwake)
        #expect(failed.issue == .assertionReleaseFailed)

        fixture.backend.clearEvents()
        fixture.backend.failReleaseKinds = []
        let recovered = fixture.service.setMode(.keepMacAndDisplaysAwake)
        #expect(fixture.backend.events == [.release(.preventUserIdleSystemSleep)])
        #expect(recovered.issue == nil)
        #expect(fixture.backend.activeKinds == [.preventUserIdleDisplaySleep])
    }

    @Test func stopReleasesAllTrackedHandlesWithoutChangingSavedMode() {
        let fixture = Fixture(initial: .keepMacAwake)
        fixture.backend.failReleaseKinds = [.preventUserIdleSystemSleep]
        _ = fixture.service.setMode(.keepMacAndDisplaysAwake)
        fixture.backend.failReleaseKinds = []
        fixture.backend.clearEvents()
        let status = fixture.service.stop()
        #expect(
            Set(fixture.backend.events)
                == Set([
                    .release(.preventUserIdleSystemSleep),
                    .release(.preventUserIdleDisplaySleep),
                ]))
        #expect(fixture.backend.activeKinds.isEmpty)
        #expect(status.persistedMode == .keepMacAndDisplaysAwake)
        #expect(status.appliedMode == .normal)
    }

    @Test func concurrentChangesNeverEnterTheBackendConcurrently() async {
        let fixture = Fixture(initial: .normal)
        fixture.backend.operationDelay = 0.002
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<30 {
                group.addTask {
                    _ = fixture.service.setMode(
                        index.isMultiple(of: 2) ? .keepMacAwake : .keepMacAndDisplaysAwake)
                }
            }
        }
        #expect(fixture.backend.maximumConcurrentOperations == 1)
        #expect(fixture.backend.activeKinds.count == 1)
    }

    @Test func fileStoreRejectsMalformedAndFutureSettingsWithoutReplacingThem() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let privateStore = try PrivateFileStore(root: root)
        try privateStore.write(Data("not-json".utf8), named: "power-control.json")
        let store = try FilePowerModeStore(root: root)
        #expect(throws: Error.self) { try store.load() }
        #expect(try privateStore.read(named: "power-control.json") == Data("not-json".utf8))

        let future = Data(#"{"version":2,"mode":"normal"}"#.utf8)
        try privateStore.write(future, named: "power-control.json")
        #expect(throws: Error.self) { try store.load() }
        #expect(try privateStore.read(named: "power-control.json") == future)
    }
}

private func kind(_ mode: PowerMode) -> PowerAssertionKind? {
    switch mode {
    case .normal: nil
    case .keepMacAwake: .preventUserIdleSystemSleep
    case .keepMacAndDisplaysAwake: .preventUserIdleDisplaySleep
    }
}

private struct Fixture {
    let store: MemoryModeStore
    let backend: RecordingBackend
    let service: PowerControlService

    init(initial: PowerMode) {
        store = MemoryModeStore(initial: initial)
        backend = RecordingBackend()
        service = PowerControlService(store: store, backend: backend)
        store.savedModes = []
    }
}

private enum StubError: Error {
    case expected
}

private final class MemoryModeStore: PowerModeStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: PowerMode?
    var failLoad = false
    var failSave = false
    var savedModes: [PowerMode] = []

    init(initial: PowerMode?) {
        value = initial
    }

    func load() throws -> PowerMode? {
        lock.lock()
        defer { lock.unlock() }
        if failLoad { throw StubError.expected }
        return value
    }

    func save(_ mode: PowerMode) throws {
        lock.lock()
        defer { lock.unlock() }
        if failSave { throw StubError.expected }
        value = mode
        savedModes.append(mode)
    }
}

private enum BackendEvent: Hashable {
    case acquire(PowerAssertionKind)
    case release(PowerAssertionKind)
}

private final class RecordingBackend: PowerAssertionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: UInt32 = 1
    private var active: [UInt32: PowerAssertionKind] = [:]
    private var recordedEvents: [BackendEvent] = []
    private var concurrentOperations = 0
    private(set) var maximumConcurrentOperations = 0
    var failAcquireKinds: Set<PowerAssertionKind> = []
    var failReleaseKinds: Set<PowerAssertionKind> = []
    var operationDelay: TimeInterval = 0

    var events: [BackendEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    var activeKinds: Set<PowerAssertionKind> {
        lock.lock()
        defer { lock.unlock() }
        return Set(active.values)
    }

    func clearEvents() {
        lock.lock()
        recordedEvents = []
        lock.unlock()
    }

    func acquire(_ kind: PowerAssertionKind) throws -> UInt32 {
        beginOperation()
        defer { endOperation() }
        lock.lock()
        defer { lock.unlock() }
        recordedEvents.append(.acquire(kind))
        if failAcquireKinds.contains(kind) { throw StubError.expected }
        let id = nextID
        nextID += 1
        active[id] = kind
        return id
    }

    func release(_ id: UInt32) throws {
        beginOperation()
        defer { endOperation() }
        lock.lock()
        defer { lock.unlock() }
        guard let kind = active[id] else { throw StubError.expected }
        recordedEvents.append(.release(kind))
        if failReleaseKinds.contains(kind) { throw StubError.expected }
        active[id] = nil
    }

    private func beginOperation() {
        lock.lock()
        concurrentOperations += 1
        maximumConcurrentOperations = max(maximumConcurrentOperations, concurrentOperations)
        let delay = operationDelay
        lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    }

    private func endOperation() {
        lock.lock()
        concurrentOperations -= 1
        lock.unlock()
    }
}
