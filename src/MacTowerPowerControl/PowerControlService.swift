import Foundation
import MacTowerCore

public final class PowerControlService: @unchecked Sendable {
    private struct Handle: Equatable {
        let id: UInt32
        let kind: PowerAssertionKind
    }

    private let lock = NSLock()
    private let store: any PowerModeStore
    private let backend: any PowerAssertionBackend
    private var handles: [Handle] = []
    private var statusValue = PowerControlStatus(
        requestedMode: .normal,
        persistedMode: nil,
        appliedMode: .normal
    )

    public convenience init(root: URL) throws {
        try self.init(
            store: FilePowerModeStore(root: root),
            backend: IOKitPowerAssertionBackend()
        )
    }

    public init(store: any PowerModeStore, backend: any PowerAssertionBackend) {
        self.store = store
        self.backend = backend
        restore()
    }

    public func status() -> PowerControlStatus {
        withLock { statusValue }
    }

    @discardableResult
    public func setMode(_ mode: PowerMode) -> PowerControlStatus {
        withLock {
            if mode == statusValue.requestedMode, statusValue.issue == nil,
                statusValue.persistedMode == mode, appliedMode() == mode
            {
                return statusValue
            }

            if mode == .normal {
                return applyNormal()
            }
            return applyNonNormal(mode)
        }
    }

    @discardableResult
    public func stop() -> PowerControlStatus {
        withLock {
            let releaseFailed = releaseHandles(where: { _ in true })
            statusValue = PowerControlStatus(
                requestedMode: statusValue.requestedMode,
                persistedMode: statusValue.persistedMode,
                appliedMode: appliedMode(),
                issue: releaseFailed ? .assertionReleaseFailed : nil
            )
            return statusValue
        }
    }

    private func restore() {
        lock.lock()
        defer { lock.unlock() }
        do {
            let saved = try store.load() ?? .normal
            statusValue = PowerControlStatus(
                requestedMode: saved,
                persistedMode: saved,
                appliedMode: .normal
            )
            guard let desiredKind = kind(for: saved) else { return }
            do {
                handles.append(Handle(id: try backend.acquire(desiredKind), kind: desiredKind))
                statusValue = PowerControlStatus(
                    requestedMode: saved, persistedMode: saved, appliedMode: saved)
            } catch {
                statusValue = PowerControlStatus(
                    requestedMode: saved,
                    persistedMode: saved,
                    appliedMode: .normal,
                    issue: .assertionCreateFailed
                )
            }
        } catch {
            statusValue = PowerControlStatus(
                requestedMode: .normal,
                persistedMode: nil,
                appliedMode: .normal,
                issue: .invalidSettings
            )
        }
    }

    private func applyNormal() -> PowerControlStatus {
        var persistenceFailed = false
        if statusValue.persistedMode != .normal {
            do {
                try store.save(.normal)
            } catch {
                persistenceFailed = true
            }
        }
        let persisted = persistenceFailed ? statusValue.persistedMode : PowerMode.normal
        let releaseFailed = releaseHandles(where: { _ in true })
        statusValue = PowerControlStatus(
            requestedMode: .normal,
            persistedMode: persisted,
            appliedMode: appliedMode(),
            issue: releaseFailed
                ? .assertionReleaseFailed
                : (persistenceFailed ? .persistenceFailed : nil)
        )
        return statusValue
    }

    private func applyNonNormal(_ mode: PowerMode) -> PowerControlStatus {
        if statusValue.persistedMode != mode {
            do {
                try store.save(mode)
            } catch {
                statusValue = PowerControlStatus(
                    requestedMode: statusValue.requestedMode,
                    persistedMode: statusValue.persistedMode,
                    appliedMode: appliedMode(),
                    issue: .persistenceFailed
                )
                return statusValue
            }
        }

        statusValue = PowerControlStatus(
            requestedMode: mode,
            persistedMode: mode,
            appliedMode: appliedMode()
        )
        guard let desiredKind = kind(for: mode) else { return statusValue }
        if !handles.contains(where: { $0.kind == desiredKind }) {
            do {
                handles.append(
                    Handle(id: try backend.acquire(desiredKind), kind: desiredKind))
            } catch {
                statusValue = PowerControlStatus(
                    requestedMode: mode,
                    persistedMode: mode,
                    appliedMode: appliedMode(),
                    issue: .assertionCreateFailed
                )
                return statusValue
            }
        }

        let releaseFailed = releaseHandles(where: { $0.kind != desiredKind })
        statusValue = PowerControlStatus(
            requestedMode: mode,
            persistedMode: mode,
            appliedMode: appliedMode(),
            issue: releaseFailed ? .assertionReleaseFailed : nil
        )
        return statusValue
    }

    private func releaseHandles(where shouldRelease: (Handle) -> Bool) -> Bool {
        var failed = false
        for handle in handles where shouldRelease(handle) {
            do {
                try backend.release(handle.id)
                handles.removeAll(where: { $0.id == handle.id })
            } catch {
                failed = true
            }
        }
        return failed
    }

    private func appliedMode() -> PowerMode {
        if handles.contains(where: { $0.kind == .preventUserIdleDisplaySleep }) {
            return .keepMacAndDisplaysAwake
        }
        if handles.contains(where: { $0.kind == .preventUserIdleSystemSleep }) {
            return .keepMacAwake
        }
        return .normal
    }

    private func kind(for mode: PowerMode) -> PowerAssertionKind? {
        switch mode {
        case .normal: nil
        case .keepMacAwake: .preventUserIdleSystemSleep
        case .keepMacAndDisplaysAwake: .preventUserIdleDisplaySleep
        }
    }

    private func withLock<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
