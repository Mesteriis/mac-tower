import CoreGraphics
import Foundation
import IOKit
import MacTowerCore
import SystemConfiguration

struct ConsoleSessionSnapshot: Equatable {
    let uid: UInt32?
    let onConsole: Bool?
    let loginDone: Bool?
}

enum SessionGate {
    static func evaluate(
        ownerUID: UInt32, consoleUID: UInt32?, onConsole: Bool?, loginDone: Bool?,
        locked: CFTypeRef?
    ) -> WindowControlAvailability {
        guard let consoleUID, let onConsole, let loginDone else { return .sessionStateUnknown }
        guard ownerUID != 0, consoleUID == ownerUID, onConsole, loginDone else {
            return .sessionInactive
        }
        guard let locked, CFGetTypeID(locked) == CFBooleanGetTypeID() else {
            return .sessionStateUnknown
        }
        return CFEqual(locked, kCFBooleanFalse) ? .ready : .sessionInactive
    }

    static func current() -> WindowControlAvailability {
        let before = sessionSnapshot()
        let activeConsoleBefore = consoleOwner()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return .sessionStateUnknown }
        defer { IOObjectRelease(root) }
        // This system key is intentionally isolated: an absent or changed type denies control.
        let locked = IORegistryEntryCreateCFProperty(
            root, "IOConsoleLocked" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        let after = sessionSnapshot()
        let activeConsoleAfter = consoleOwner()
        return evaluateConfirmedSession(
            ownerUID: getuid(), before: before, after: after,
            activeConsoleBefore: activeConsoleBefore, activeConsoleAfter: activeConsoleAfter,
            locked: locked)
    }

    static func evaluateConfirmedSession(
        ownerUID: UInt32, before: ConsoleSessionSnapshot?, after: ConsoleSessionSnapshot?,
        activeConsoleBefore: UInt32?, activeConsoleAfter: UInt32?, locked: CFTypeRef?
    ) -> WindowControlAvailability {
        guard let before, let after, let activeConsoleBefore, let activeConsoleAfter else {
            return .sessionStateUnknown
        }
        guard activeConsoleBefore == ownerUID, activeConsoleAfter == ownerUID,
            before.uid == ownerUID, after.uid == ownerUID
        else { return .sessionInactive }
        guard before == after else { return .sessionStateUnknown }
        return evaluate(
            ownerUID: ownerUID,
            consoleUID: after.uid,
            onConsole: after.onConsole,
            loginDone: after.loginDone,
            locked: locked
        )
    }

    private static func sessionSnapshot() -> ConsoleSessionSnapshot? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return ConsoleSessionSnapshot(
            uid: (session[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value,
            onConsole: strictBoolean(session[kCGSessionOnConsoleKey as String]),
            loginDone: strictBoolean(session[kCGSessionLoginDoneKey as String]))
    }

    private static func consoleOwner() -> UInt32? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) != nil else { return nil }
        return uid
    }

    private static func strictBoolean(_ value: Any?) -> Bool? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        return CFEqual(value as CFTypeRef, kCFBooleanTrue)
    }
}
