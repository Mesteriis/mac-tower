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

    func stop() async {
        await power.stopPower()
        await network.stop()
    }
}
