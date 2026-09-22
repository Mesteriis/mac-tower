import MacTowerWindowControl

@MainActor
final class AppServices {
    let windows = WindowController()
    let loginItem = LoginItemController()
    let daemon = DaemonClient()
    lazy var windowBridge = WindowAgentBridge(controller: windows)
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
    }
}
