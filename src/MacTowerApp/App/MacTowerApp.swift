import SwiftUI

@main
struct MacTowerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("showMenuBarTitle") private var showMenuBarTitle = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(daemon: appDelegate.services.daemon, windows: appDelegate.services.windows)
        } label: {
            if showMenuBarTitle {
                Label("MacTower", systemImage: "antenna.radiowaves.left.and.right")
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .accessibilityLabel("MacTower")
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(
                daemon: appDelegate.services.daemon,
                windows: appDelegate.services.windows,
                windowBridge: appDelegate.services.windowBridge,
                loginItem: appDelegate.services.loginItem
            )
        }
    }
}
