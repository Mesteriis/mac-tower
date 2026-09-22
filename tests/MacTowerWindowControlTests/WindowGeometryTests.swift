import CoreFoundation
import Foundation
import MacTowerCore
import Testing

@testable import MacTowerWindowControl

@Suite("Window geometry and session gate")
struct WindowGeometryTests {
    @Test("AX coordinate conversion preserves logical points and flips the primary origin")
    func coordinateConversion() {
        let primary = WindowRect(x: 0, y: 0, width: 1728, height: 1117)
        let left = WindowRect(x: -1920, y: 24, width: 1920, height: 1056)
        #expect(
            WindowGeometry.accessibilityRect(left, primaryFrame: primary)
                == WindowRect(x: -1920, y: 37, width: 1920, height: 1056))
        let above = WindowRect(x: 100, y: 1117, width: 1440, height: 875)
        #expect(
            WindowGeometry.accessibilityRect(above, primaryFrame: primary)
                == WindowRect(x: 100, y: -875, width: 1440, height: 875))
    }

    @Test("Frame verification tolerates rounding but detects an app's minimum size")
    func approximateFrame() {
        let wanted = WindowRect(x: 0, y: 25, width: 1440, height: 850)
        #expect(WindowGeometry.matches(wanted, WindowRect(x: 0.5, y: 25, width: 1440, height: 850)))
        #expect(!WindowGeometry.matches(wanted, WindowRect(x: 0, y: 25, width: 1600, height: 850)))
    }

    @Test("Unknown lock state and a different console owner fail closed")
    func sessionGate() {
        #expect(
            SessionGate.evaluate(
                ownerUID: 501, consoleUID: 501, onConsole: true, loginDone: true,
                locked: kCFBooleanFalse) == .ready)
        #expect(
            SessionGate.evaluate(
                ownerUID: 501, consoleUID: 501, onConsole: true, loginDone: true,
                locked: kCFBooleanTrue) == .sessionInactive)
        #expect(
            SessionGate.evaluate(
                ownerUID: 501, consoleUID: 502, onConsole: true, loginDone: true,
                locked: kCFBooleanFalse) == .sessionInactive)
        #expect(
            SessionGate.evaluate(
                ownerUID: 501, consoleUID: 501, onConsole: true, loginDone: true, locked: nil)
                == .sessionStateUnknown)
        #expect(
            SessionGate.evaluate(
                ownerUID: 501, consoleUID: 501, onConsole: true, loginDone: true,
                locked: NSNumber(value: 0)) == .sessionStateUnknown)
    }

    @Test("Mixed console snapshots and an unknown SystemConfiguration owner never unlock control")
    func consoleTransition() {
        let owner = ConsoleSessionSnapshot(uid: 501, onConsole: true, loginDone: true)
        let different = ConsoleSessionSnapshot(uid: 502, onConsole: true, loginDone: true)
        #expect(
            SessionGate.evaluateConfirmedSession(
                ownerUID: 501, before: owner, after: owner, activeConsoleBefore: 501,
                activeConsoleAfter: 501, locked: kCFBooleanFalse) == .ready)
        #expect(
            SessionGate.evaluateConfirmedSession(
                ownerUID: 501, before: owner, after: different, activeConsoleBefore: 501,
                activeConsoleAfter: 502, locked: kCFBooleanFalse) == .sessionInactive)
        #expect(
            SessionGate.evaluateConfirmedSession(
                ownerUID: 501, before: owner, after: owner, activeConsoleBefore: 501,
                activeConsoleAfter: nil, locked: kCFBooleanFalse) == .sessionStateUnknown)
        #expect(
            SessionGate.evaluateConfirmedSession(
                ownerUID: 501, before: owner, after: owner, activeConsoleBefore: 502,
                activeConsoleAfter: 502, locked: kCFBooleanFalse) == .sessionInactive)
    }
}
