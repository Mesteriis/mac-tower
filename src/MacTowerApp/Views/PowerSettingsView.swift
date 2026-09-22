import MacTowerCore
import SwiftUI

struct PowerSettingsView: View {
    @ObservedObject var daemon: DaemonClient

    var body: some View {
        Section("Sleep") {
            Picker("Sleep mode", selection: selection) {
                ForEach(PowerMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(daemon.powerStatus == nil || daemon.isPowerModeBusy || daemon.isBusy)

            if let status = daemon.powerStatus {
                if status.persistedMode != status.requestedMode {
                    LabeledContent(
                        "Saved mode",
                        value: status.persistedMode?.displayName ?? "Unknown"
                    )
                }
                if status.appliedMode != status.requestedMode {
                    LabeledContent("Applied mode", value: status.appliedMode.displayName)
                }
                if let issue = status.issue {
                    Text(issue.explanation).foregroundStyle(.red)
                }
            } else {
                Text("Install and start the MacTower service to control sleep.")
                    .foregroundStyle(.secondary)
            }

            if let error = daemon.powerPresentation.errorMessage {
                Text(error).foregroundStyle(.red)
            }

            Text(
                "Keeping the Mac or displays awake uses more energy. MacTower does not override manual sleep, lid closure, screen locking, or critical-battery protection."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var selection: Binding<PowerMode> {
        Binding(
            get: { daemon.powerPresentation.displayedMode ?? .normal },
            set: { mode in Task { await daemon.setPowerMode(mode) } }
        )
    }
}
