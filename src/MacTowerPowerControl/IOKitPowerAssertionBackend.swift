import Foundation
import IOKit.pwr_mgt

public enum IOKitPowerAssertionError: Error, Equatable {
    case createFailed(IOReturn)
    case releaseFailed(IOReturn)
}

public struct IOKitPowerAssertionBackend: PowerAssertionBackend, Sendable {
    public init() {}

    public func acquire(_ kind: PowerAssertionKind) throws -> UInt32 {
        let type: CFString
        let name: CFString
        switch kind {
        case .preventUserIdleSystemSleep:
            type = kIOPMAssertPreventUserIdleSystemSleep as CFString
            name = "MacTower keep Mac awake" as CFString
        case .preventUserIdleDisplaySleep:
            type = kIOPMAssertPreventUserIdleDisplaySleep as CFString
            name = "MacTower keep Mac and displays awake" as CFString
        }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type, IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &id)
        guard result == kIOReturnSuccess else {
            throw IOKitPowerAssertionError.createFailed(result)
        }
        return id
    }

    public func release(_ id: UInt32) throws {
        let result = IOPMAssertionRelease(id)
        guard result == kIOReturnSuccess else {
            throw IOKitPowerAssertionError.releaseFailed(result)
        }
    }
}
