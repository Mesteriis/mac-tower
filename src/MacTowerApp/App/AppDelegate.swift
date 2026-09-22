import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "dev.mactower.app", category: "lifecycle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The menu bar UI belongs to the logged-in user's GUI session.
        NSApp.setActivationPolicy(.accessory)
        logger.info("MacTower menu bar application started; network endpoints are not implemented.")
    }
}
