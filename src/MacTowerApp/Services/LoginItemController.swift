import Combine
import Foundation
import ServiceManagement

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?

    var isRegistered: Bool { status == .enabled || status == .requiresApproval }

    var statusDescription: String {
        switch status {
        case .enabled: "Enabled"
        case .notRegistered: "Off"
        case .requiresApproval: "Approval required in Login Items"
        case .notFound: "App service not found"
        @unknown default: "Unknown"
        }
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer {
            refresh()
            isBusy = false
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "Could not update launch at login. \(error.localizedDescription)"
        }
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
