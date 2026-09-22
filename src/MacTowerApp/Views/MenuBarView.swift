import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("MacTower")
        Text("Network: not implemented")
            .foregroundStyle(.secondary)

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
    }
}
