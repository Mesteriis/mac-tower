import AppKit
import MacTowerCore
import MacTowerWindowControl
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var daemon: DaemonClient
    @ObservedObject var windows: WindowController

    var body: some View {
        Text("MacTower")
        Text(daemon.status?.running == true ? "Service: running" : "Service: unavailable")
            .foregroundStyle(.secondary)

        if let accounts = daemon.status?.accounts {
            Text("AI accounts: \(accounts.count)")
                .foregroundStyle(.secondary)
        }

        Divider()

        Menu("Move active window to") {
            ForEach(Array(windows.snapshot.displays.enumerated()), id: \.element.id) {
                index, display in
                Button(shortTitle("\(index + 1). \(display.name)")) {
                    Task { await windows.move(to: display.id, useMenuTarget: true) }
                }
            }
            if windows.snapshot.displays.isEmpty { Text("No displays available") }
        }
        .disabled(windows.snapshot.availability != .ready || windows.snapshot.displays.isEmpty)
        if windows.snapshot.availability != .ready {
            Text(windows.snapshot.availability.displayName).foregroundStyle(.secondary)
        }
        if let result = windows.lastResult {
            Text(result.code.displayName).foregroundStyle(.secondary)
        }

        Divider()

        Menu("Sleep mode") {
            ForEach(PowerMode.allCases, id: \.self) { mode in
                if daemon.powerStatus?.requestedMode == mode {
                    Button {
                        Task { await daemon.setPowerMode(mode) }
                    } label: {
                        Label(mode.displayName, systemImage: "checkmark")
                    }
                } else {
                    Button(mode.displayName) {
                        Task { await daemon.setPowerMode(mode) }
                    }
                }
            }
        }
        .disabled(daemon.powerStatus == nil || daemon.isPowerModeBusy || daemon.isBusy)
        if let issue = daemon.powerStatus?.issue {
            Text(issue.explanation).foregroundStyle(.secondary)
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
        .onAppear { Task { await daemon.refresh() } }
    }

    private func shortTitle(_ title: String) -> String {
        title.count > 30 ? String(title.prefix(29)) + "…" : title
    }
}
