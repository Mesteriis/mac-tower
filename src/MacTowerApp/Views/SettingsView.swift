import AppKit
import MacTowerCore
import SwiftUI

struct SettingsView: View {
    @AppStorage("showMenuBarTitle") private var showMenuBarTitle = false
    @StateObject private var daemon = DaemonClient()

    var body: some View {
        TabView {
            AccountsSettingsView(daemon: daemon)
                .tabItem { Label("Accounts", systemImage: "person.2") }

            NetworkSettingsView(daemon: daemon)
                .tabItem { Label("Publishing", systemImage: "network") }

            Form {
                Section("Menu bar") {
                    Toggle("Show app name", isOn: $showMenuBarTitle)
                }
                Section("Privileged service") {
                    LabeledContent(
                        "State", value: daemon.status?.running == true ? "Running" : "Unavailable")
                    Text(
                        "Installation and upgrades are explicit: make install. Removing the service preserves account data."
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
        .frame(width: 720, height: 590)
        .task { await daemon.refresh() }
    }
}

private struct AccountsSettingsView: View {
    @ObservedObject var daemon: DaemonClient
    @StateObject private var form = AccountsFormModel()

    var body: some View {
        Form {
            if let error = daemon.errorMessage {
                Text(error).foregroundStyle(.red)
            }

            Section("Connected accounts") {
                if daemon.status?.accounts.isEmpty != false {
                    Text("No accounts connected").foregroundStyle(.secondary)
                } else {
                    ForEach(daemon.status?.accounts ?? [], id: \.id) { account in
                        HStack {
                            Label(account.label, systemImage: icon(for: account.provider))
                            Spacer()
                            Text(account.provider.rawValue.capitalized)
                                .foregroundStyle(.secondary)
                            Button("Remove", role: .destructive) {
                                Task { await daemon.remove(account.id) }
                            }
                            .disabled(daemon.isBusy)
                        }
                    }
                }
            }

            Section("Codex") {
                accountFields(id: $form.codexID, label: $form.codexLabel)
                Button("Connect with OAuth…") {
                    Task {
                        if let url = await daemon.startCodex(
                            id: form.codexID, label: form.codexLabel
                        ) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .disabled(daemon.isBusy)
                if let activeID = daemon.status?.activeCodexOAuthAccountID {
                    HStack {
                        Text("OAuth waiting for \(activeID.rawValue)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel OAuth", role: .destructive) {
                            Task { await daemon.cancelCodexOAuth(id: activeID) }
                        }
                        .disabled(daemon.isBusy)
                    }
                }
                Text(
                    "Each account uses an isolated CODEX_HOME and the installed, pinned Codex app-server binary."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("Claude Code 2.1.251+") {
                accountFields(id: $form.claudeID, label: $form.claudeLabel)
                TextField("CLAUDE_CONFIG_DIR", text: $form.claudeConfigDirectory)
                TextField("Statusline snapshot path", text: $form.claudeSnapshotPath)
                HStack {
                    Button("Install bridge and link") {
                        Task {
                            await daemon.linkClaude(
                                id: form.claudeID,
                                label: form.claudeLabel,
                                configDirectory: form.claudeConfigDirectory,
                                snapshotPath: form.claudeSnapshotPath
                            )
                        }
                    }
                    Button("Restore previous statusline") {
                        Task {
                            await daemon.restoreClaudeStatusline(
                                configDirectory: form.claudeConfigDirectory)
                        }
                    }
                }
                .disabled(daemon.isBusy)
                Text(
                    "MacTower reads only the latest filtered statusline snapshot. It never generates model requests to refresh Claude usage."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("DeepSeek API") {
                accountFields(id: $form.deepSeekID, label: $form.deepSeekLabel)
                SecureField("API key", text: $form.deepSeekKey)
                Button("Save API key") {
                    let key = form.deepSeekKey
                    form.deepSeekKey = ""
                    Task {
                        await daemon.addDeepSeek(
                            id: form.deepSeekID,
                            label: form.deepSeekLabel,
                            apiKey: key
                        )
                    }
                }
                .disabled(daemon.isBusy || form.deepSeekKey.isEmpty)
                Text("DeepSeek has no public OAuth flow here. Key replacement is always explicit.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Cursor") {
                HStack {
                    Label("Cursor", systemImage: "cursorarrow")
                    Spacer()
                    Text("Soon").foregroundStyle(.secondary)
                }
                .disabled(true)
                Text(
                    "No import, authorization access, or network requests are implemented for Cursor."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func accountFields(id: Binding<String>, label: Binding<String>) -> some View {
        TextField("Stable account ID", text: id)
        TextField("Display name", text: label)
    }

    private func icon(for provider: AIProvider) -> String {
        switch provider {
        case .codex: "terminal"
        case .claude: "brain"
        case .deepSeek: "banknote"
        case .cursor: "cursorarrow"
        }
    }
}

@MainActor
private final class AccountsFormModel: ObservableObject {
    @Published var codexID = "codex-personal"
    @Published var codexLabel = "Codex Personal"
    @Published var claudeID = "claude-personal"
    @Published var claudeLabel = "Claude Personal"
    @Published var claudeConfigDirectory = NSHomeDirectory() + "/.claude"
    @Published var claudeSnapshotPath =
        NSHomeDirectory()
        + "/Library/Application Support/MacTower/claude/claude-personal.json"
    @Published var deepSeekID = "deepseek-main"
    @Published var deepSeekLabel = "DeepSeek"
    @Published var deepSeekKey = ""
}

private struct NetworkSettingsView: View {
    @ObservedObject var daemon: DaemonClient
    @StateObject private var form = NetworkFormModel()

    var body: some View {
        Form {
            if let error = daemon.errorMessage {
                Text(error).foregroundStyle(.red)
            }
            Section("Collection") {
                TextField("Poll interval, seconds (minimum 60)", text: $form.pollInterval)
            }
            Section("Published sensors") {
                Toggle("All connected accounts", isOn: $form.publishAllAccounts)
                if !form.publishAllAccounts {
                    ForEach(daemon.status?.accounts ?? [], id: \.id) { account in
                        Toggle(
                            account.label,
                            isOn: Binding(
                                get: { form.selectedAccountIDs.contains(account.id.rawValue) },
                                set: { selected in
                                    if selected {
                                        form.selectedAccountIDs.insert(account.id.rawValue)
                                    } else {
                                        form.selectedAccountIDs.remove(account.id.rawValue)
                                    }
                                }
                            )
                        )
                    }
                }
                ForEach(PublishedSensorField.allCases, id: \.self) { field in
                    Toggle(
                        field.displayName,
                        isOn: Binding(
                            get: { form.selectedFields.contains(field) },
                            set: { selected in
                                if selected {
                                    form.selectedFields.insert(field)
                                } else {
                                    form.selectedFields.remove(field)
                                }
                            }
                        )
                    )
                }
                Text("The same account and field selection is applied to HTTP and MQTT.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("HTTP · read only") {
                Toggle("Enable HTTP", isOn: $form.httpEnabled)
                TextField("Bind IPv4 address", text: $form.httpAddress)
                TextField("Port", text: $form.httpPort)
                TextField("Allowed IPv4 subnets, comma separated", text: $form.allowedCIDRs)
                Text(
                    "Only GET /health, /v1/accounts and /v1/sensors are exposed. The bind address must be inside the allowlist."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("MQTT · Home Assistant Discovery") {
                Toggle("Enable MQTT", isOn: $form.mqttEnabled)
                TextField("Broker host", text: $form.mqttHost)
                TextField("Port", text: $form.mqttPort)
                Toggle("Verify TLS certificate", isOn: $form.mqttTLS)
                TextField("Username (optional)", text: $form.mqttUsername)
                SecureField("New password (leave blank to keep)", text: $form.mqttPassword)
                Toggle("Clear stored broker password", isOn: $form.clearMQTTPassword)
                TextField("Topic prefix", text: $form.mqttTopic)
            }
            Section {
                Button("Save service configuration") { save() }
                    .disabled(daemon.isBusy)
                Text(
                    "Listener changes take effect after the daemon restarts. Network publishing remains disabled until you enable and save it."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(daemon.$status) { status in
            if let configuration = status?.configuration {
                form.apply(configuration)
            }
        }
    }

    private func save() {
        do {
            guard let interval = Int(form.pollInterval), let webPort = Int(form.httpPort),
                let brokerPort = Int(form.mqttPort)
            else { throw ServiceConfigurationError.invalidPort }
            let networks = try form.allowedCIDRs.split(separator: ",")
                .map { try IPv4CIDR($0.trimmingCharacters(in: .whitespaces)) }
            let http = try HTTPServiceConfiguration(
                enabled: form.httpEnabled,
                bindAddress: form.httpAddress,
                port: webPort,
                allowedNetworks: networks
            )
            let mqtt = try MQTTServiceConfiguration(
                enabled: form.mqttEnabled,
                host: form.mqttHost,
                port: brokerPort,
                useTLS: form.mqttTLS,
                username: form.mqttUsername.isEmpty ? nil : form.mqttUsername,
                topicPrefix: form.mqttTopic
            )
            let configuration = try ServiceConfiguration(
                pollIntervalSeconds: interval,
                http: http,
                mqtt: mqtt,
                publication: try PublicationSelection(
                    accountIDs: form.publishAllAccounts
                        ? nil : Set(form.selectedAccountIDs.map { AccountID($0) }),
                    fields: form.selectedFields
                )
            )
            let password: String? =
                form.clearMQTTPassword
                ? "" : (form.mqttPassword.isEmpty ? nil : form.mqttPassword)
            form.mqttPassword = ""
            form.clearMQTTPassword = false
            Task { await daemon.save(configuration: configuration, mqttPassword: password) }
        } catch {
            daemon.errorMessage = "Invalid network configuration."
        }
    }
}

@MainActor
private final class NetworkFormModel: ObservableObject {
    @Published var pollInterval = "300"
    @Published var httpEnabled = false
    @Published var httpAddress = "192.168.1.10"
    @Published var httpPort = "8787"
    @Published var allowedCIDRs = "192.168.1.0/24"
    @Published var mqttEnabled = false
    @Published var mqttHost = "192.168.1.2"
    @Published var mqttPort = "1883"
    @Published var mqttTLS = false
    @Published var mqttUsername = ""
    @Published var mqttPassword = ""
    @Published var clearMQTTPassword = false
    @Published var mqttTopic = "mac_tower"
    @Published var publishAllAccounts = true
    @Published var selectedAccountIDs: Set<String> = []
    @Published var selectedFields = Set(PublishedSensorField.allCases)

    func apply(_ configuration: ServiceConfiguration) {
        pollInterval = String(configuration.pollIntervalSeconds)
        httpEnabled = configuration.http.enabled
        httpAddress = configuration.http.bindAddress
        httpPort = String(configuration.http.port)
        allowedCIDRs = configuration.http.allowedNetworks.map(\.description).joined(separator: ", ")
        mqttEnabled = configuration.mqtt.enabled
        mqttHost = configuration.mqtt.host
        mqttPort = String(configuration.mqtt.port)
        mqttTLS = configuration.mqtt.useTLS
        mqttUsername = configuration.mqtt.username ?? ""
        mqttTopic = configuration.mqtt.topicPrefix
        publishAllAccounts = configuration.publication.accountIDs == nil
        selectedAccountIDs = Set(configuration.publication.accountIDs?.map(\.rawValue) ?? [])
        selectedFields = configuration.publication.fields
    }
}

extension PublishedSensorField {
    fileprivate var displayName: String {
        switch self {
        case .quotaUsed: "Quota used"
        case .quotaRemaining: "Quota remaining"
        case .quotaWindowDuration: "Quota window duration"
        case .quotaResetsAt: "Quota reset time"
        case .resetCredits: "Reset credits"
        case .balanceTotal: "Total balance"
        case .balanceGranted: "Granted balance"
        case .balanceToppedUp: "Topped-up balance"
        }
    }
}
