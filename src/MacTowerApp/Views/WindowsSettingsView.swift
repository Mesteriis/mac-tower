import AppKit
import MacTowerCore
import MacTowerWindowControl
import SwiftUI

struct WindowsSettingsView: View {
    @ObservedObject var windows: WindowController
    @ObservedObject var bridge: WindowAgentBridge
    @ObservedObject var loginItem: LoginItemController

    var body: some View {
        Form {
            Section("Move active windows") {
                LabeledContent("State", value: windows.snapshot.availability.displayName)
                Text(
                    "Choose a display from the MacTower menu to move the active window. Normal windows fill the display's usable area. Fullscreen windows exit fullscreen, move, then attempt to enter fullscreen again."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                HStack {
                    Button("Grant Accessibility…") { windows.requestAccessibilityPermission() }
                    Button("Refresh") {
                        Task { await windows.refresh() }
                        loginItem.refresh()
                    }
                }
                Text("Enable MacTower in System Settings → Privacy & Security → Accessibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let result = windows.lastResult {
                    LabeledContent("Last action", value: result.code.displayName)
                }
            }

            Section("Connected displays") {
                if windows.snapshot.displays.isEmpty {
                    Text("No displays available").foregroundStyle(.secondary)
                }
                ForEach(windows.snapshot.displays) { display in
                    LabeledContent(display.name) {
                        Text(
                            "\(display.isPrimary ? "Primary · " : "")\(Int(display.frame.width)) × \(Int(display.frame.height)) pt"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Home Assistant") {
                Toggle(
                    "Allow Home Assistant to move windows",
                    isOn: Binding(
                        get: { bridge.remoteEnabled },
                        set: { enabled in Task { await bridge.setRemoteEnabled(enabled) } }
                    )
                )
                .disabled(!bridge.isConnected || bridge.isUpdatingPreference)
                Text(
                    "Requires MQTT publishing and an active, unlocked owner session with MacTower running. Commands are discarded when control is unavailable. Changes take effect immediately."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(
                    "Anyone allowed to publish commands on the configured broker can move your windows. Restrict command-topic access to trusted clients."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                LabeledContent(
                    "Service connection", value: bridge.isConnected ? "Connected" : "Unavailable")
                if let error = bridge.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Login") {
                Toggle(
                    "Open MacTower at login",
                    isOn: Binding(
                        get: { loginItem.isRegistered },
                        set: { enabled in Task { await loginItem.setEnabled(enabled) } }
                    )
                )
                .disabled(loginItem.isBusy)
                LabeledContent("Status", value: loginItem.statusDescription)
                if loginItem.status == .requiresApproval {
                    Button("Open Login Items Settings…") { loginItem.openSettings() }
                }
                if let error = loginItem.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            loginItem.refresh()
            await windows.refresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            loginItem.refresh()
            Task { await windows.refresh() }
        }
    }
}
