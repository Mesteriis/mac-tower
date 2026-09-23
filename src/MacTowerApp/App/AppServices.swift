import MacTowerWindowControl

@MainActor
final class AppServices {
    let windows = WindowController()
    let loginItem = LoginItemController()
    let daemon = DaemonClient()
    lazy var notifications = MacNotificationController(
        center: SystemUserNotificationCenter(),
        acknowledger: daemon
    )
    lazy var windowBridge = WindowAgentBridge(
        controller: windows,
        notificationController: notifications
    )
    private var menuCapture: MenuTargetCapture?

    func start() {
        windows.start()
        menuCapture = MenuTargetCapture(controller: windows)
        windowBridge.start()
    }

    func stop() {
        menuCapture?.stop()
        menuCapture = nil
        windowBridge.stop()
        daemon.stop()
    }
}
