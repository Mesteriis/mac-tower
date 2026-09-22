import MacTowerPowerControl

protocol PowerStopping: Sendable {
    func stopPower() async
}

protocol NetworkStopping: Sendable {
    func stop() async
}

extension PowerControlService: PowerStopping {
    func stopPower() async {
        _ = stop()
    }
}

extension DaemonNetworkRuntime: NetworkStopping {}

struct DaemonLifecycle: Sendable {
    let power: any PowerStopping
    let network: any NetworkStopping
    let notifications: (any NotificationStopping)?

    init(
        power: any PowerStopping,
        network: any NetworkStopping,
        notifications: (any NotificationStopping)? = nil
    ) {
        self.power = power
        self.network = network
        self.notifications = notifications
    }

    func stop() async {
        await notifications?.stopNotifications()
        await power.stopPower()
        await network.stop()
    }
}
