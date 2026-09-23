import AppKit
import ApplicationServices
import ColorSync
import MacTowerCore

@MainActor
enum NativeWindowEnvironment {
    static func capture() -> WindowEnvironment {
        let session = SessionGate.current()
        let availability: WindowControlAvailability =
            session != .ready
            ? session
            : AXIsProcessTrusted() ? .ready : .accessibilityRequired
        var seen = Set<String>()
        let primaryID = CGMainDisplayID()
        var displays: [WindowDisplay] = []
        for screen in NSScreen.screens {
            guard
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber
            else { continue }
            let displayID = number.uint32Value
            let mirrored = CGDisplayMirrorsDisplay(displayID)
            let logicalID = mirrored == kCGNullDirectDisplay ? displayID : mirrored
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(logicalID)?.takeRetainedValue() else {
                continue
            }
            let id = (CFUUIDCreateString(kCFAllocatorDefault, uuid) as String).lowercased()
            guard seen.insert(id).inserted else { continue }
            displays.append(
                WindowDisplay(
                    id: id, name: String(screen.localizedName.prefix(100)),
                    frame: rect(screen.frame), visibleFrame: rect(screen.visibleFrame),
                    isPrimary: logicalID == primaryID
                ))
        }
        let duplicates = Dictionary(grouping: displays, by: \.name)
        displays = displays.map { display in
            guard duplicates[display.name, default: []].count > 1 else { return display }
            return WindowDisplay(
                id: display.id, name: "\(display.name) (\(display.id.prefix(8)))",
                frame: display.frame, visibleFrame: display.visibleFrame,
                isPrimary: display.isPrimary)
        }.sorted { ($0.isPrimary ? 0 : 1, $0.name, $0.id) < ($1.isPrimary ? 0 : 1, $1.name, $1.id) }
        guard displays.count <= 32, displays.contains(where: \.isPrimary) else {
            return WindowEnvironment(displays: [], availability: .unavailable)
        }
        return WindowEnvironment(displays: displays, availability: availability)
    }

    private static func rect(_ rect: NSRect) -> WindowRect {
        WindowRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }
}

/// Tracks an external foreground app before an accessory menu can become frontmost.
@MainActor
final class FrontmostApplicationTracker: NSObject {
    private var lastExternalPID: Int32?
    override init() {
        super.init()
        remember(NSWorkspace.shared.frontmostApplication)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self, selector: #selector(didActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func didActivate(_ notification: Notification) {
        remember(
            notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    func focusedPID(allowMenuFallback: Bool) -> Int32? {
        let app = NSWorkspace.shared.frontmostApplication
        if app?.processIdentifier == getpid() {
            // A Settings window is a genuine focus change, unlike the accessory's menu tracking.
            return allowMenuFallback && NSApp.keyWindow == nil ? lastExternalPID : nil
        }
        remember(app)
        return app?.activationPolicy == .regular ? app?.processIdentifier : nil
    }

    private func remember(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != getpid() else { return }
        lastExternalPID = app.activationPolicy == .regular ? app.processIdentifier : nil
    }
}
