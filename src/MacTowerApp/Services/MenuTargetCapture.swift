import AppKit
import MacTowerWindowControl

/// SwiftUI does not expose the menu's tracking lifecycle. Capture synchronously
/// when the root AppKit menu begins tracking, before any action activates MacTower.
@MainActor
final class MenuTargetCapture: NSObject {
    private weak var controller: WindowController?

    init(controller: WindowController) {
        self.controller = controller
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification, object: nil)
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu, menu.supermenu == nil else { return }
        controller?.captureMenuTarget()
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        controller = nil
    }
}
