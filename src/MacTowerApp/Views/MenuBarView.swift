import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openSettings) private var openSettings
    @StateObject private var daemon = DaemonClient()

    var body: some View {
        Text("MacTower")
        Text(daemon.status?.running == true ? "Service: running" : "Service: unavailable")
            .foregroundStyle(.secondary)

        if let accounts = daemon.status?.accounts {
            Text("AI accounts: \(accounts.count)")
                .foregroundStyle(.secondary)
        }

        Divider()

        Button("Settings…", systemImage: "gearshape") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit MacTower") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
        .task { await daemon.refresh() }
    }
}
