import Foundation

public enum PowerAssertionKind: Hashable, Sendable {
    case preventUserIdleSystemSleep
    case preventUserIdleDisplaySleep
}

public protocol PowerAssertionBackend: Sendable {
    func acquire(_ kind: PowerAssertionKind) throws -> UInt32
    func release(_ id: UInt32) throws
}
