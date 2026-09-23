import Foundation
import MacTowerCore

actor WindowControlService {
    private struct Settings: Codable {
        let installationID: UUID
        var enabled: Bool
    }

    nonisolated let router: WindowCommandRouter
    nonisolated let installationID: UUID
    private let storage: PrivateFileStore
    private var settings: Settings

    init(root: URL) throws {
        storage = try PrivateFileStore(root: root)
        if let data = try storage.read(named: "window-control.json") {
            settings = try JSONDecoder().decode(Settings.self, from: data)
        } else {
            settings = Settings(installationID: UUID(), enabled: false)
            try storage.write(try JSONEncoder().encode(settings), named: "window-control.json")
        }
        installationID = settings.installationID
        router = WindowCommandRouter(enabled: settings.enabled)
    }

    func setEnabled(_ enabled: Bool) async throws -> WindowBridgeStatus {
        // Turning control off must fail closed even if persistence is unavailable.
        if !enabled { await router.setEnabled(false) }
        var replacement = settings
        replacement.enabled = enabled
        try storage.write(try JSONEncoder().encode(replacement), named: "window-control.json")
        settings = replacement
        await router.setEnabled(enabled)
        return await status()
    }

    func status() async -> WindowBridgeStatus {
        let state = await router.state()
        return WindowBridgeStatus(enabled: state.enabled, epoch: state.epoch)
    }
}
