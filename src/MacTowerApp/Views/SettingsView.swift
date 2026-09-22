import SwiftUI

struct SettingsView: View {
    @AppStorage("showMenuBarTitle") private var showMenuBarTitle = false

    var body: some View {
        TabView {
            Form {
                Section("Menu bar") {
                    Toggle("Show app name", isOn: $showMenuBarTitle)
                }

                Section("Service scaffold") {
                    LabeledContent("Network endpoints", value: "Not implemented")
                    LabeledContent("Service installation", value: "Not included yet")
                    Text(
                        "The root daemon is a separate executable. This app runs in your login session."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500, height: 340)
    }
}
