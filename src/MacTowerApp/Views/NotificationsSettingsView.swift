import AppKit
import MacTowerCore
import SwiftUI

enum NotificationServiceHealth: Equatable {
    case unknown
    case disabled
    case healthy

    var isHealthy: Bool { self == .healthy }

    var label: String {
        switch self {
        case .unknown: "Unknown"
        case .disabled: "Disabled"
        case .healthy: "Running"
        }
    }
}

struct NotificationTestAction: Equatable, Identifiable {
    let title: String
    let channel: NotificationTestChannel

    var id: String { channel.rawValue }
}

enum NotificationPresentation {
    static func serviceHealth(_ summary: NotificationSummary?) -> NotificationServiceHealth {
        guard let summary else { return .unknown }
        return summary.engine.configuration.enabled ? .healthy : .disabled
    }

    static func panelStatus(
        availability: NotificationChannelAvailability,
        tokenPresent: Bool
    ) -> String {
        guard tokenPresent else { return "Not paired" }
        return switch availability {
        case .disabled: "Disabled"
        case .unavailable: "Offline"
        case .available: "Available"
        }
    }

    static func deliveryLabel(_ state: NotificationDeliveryState) -> String {
        switch state {
        case .suppressed: "Suppressed"
        case .queued: "Queued"
        case .handedOff: "Handed off"
        case .failed: "Failed"
        }
    }

    static func authorizationMessage(_ authorization: MacNotificationAuthorization) -> String {
        switch authorization {
        case .notDetermined: "Allow MacTower to show notifications on this Mac."
        case .denied: "Open System Settings and allow notifications for MacTower."
        case .authorized: "Mac notifications are allowed."
        }
    }

    static func activeCriticalLabel(_ count: Int) -> String {
        switch count {
        case 0: "No active critical alerts"
        case 1: "1 active critical alert"
        default: "\(count) active critical alerts"
        }
    }

    static func ruleLabel(hasOverride: Bool) -> String {
        hasOverride ? "Custom rule" : "Inherits global rule"
    }

    static func pairingInstructions(_ status: NSPanelPairingStatus) -> String {
        switch status {
        case .pressDone: "Approve the request on the panel, press Done, then pair again."
        case .paired: "Panel paired"
        }
    }

    static let testActions = [
        NotificationTestAction(title: "Test Mac", channel: .mac),
        NotificationTestAction(title: "Test panel text", channel: .panelText),
        NotificationTestAction(title: "Test panel wake", channel: .panelWake),
        NotificationTestAction(title: "Test panel sound", channel: .panelSound),
    ]
}

struct NotificationsSettingsView: View {
    @ObservedObject var daemon: DaemonClient
    @ObservedObject var macNotifications: MacNotificationController

    @StateObject private var form = NotificationSettingsFormModel()

    private var configuration: NotificationConfiguration {
        get { form.configuration }
        nonmutating set { form.configuration = newValue }
    }

    private var configurationBinding: Binding<NotificationConfiguration> {
        Binding(
            get: { form.configuration },
            set: { form.configuration = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(
                "Notifications section",
                selection: Binding(
                    get: { form.section },
                    set: { form.section = $0 })
            ) {
                ForEach(NotificationSettingsSection.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            Divider()

            switch form.section {
            case .configuration:
                configurationView
            case .history:
                NotificationHistoryView(daemon: daemon)
            }
        }
        .task {
            await macNotifications.refreshAuthorization()
            applyDaemonConfiguration(daemon.status?.notificationSummary)
        }
        .onReceive(daemon.$status) { status in
            applyDaemonConfiguration(status?.notificationSummary)
        }
    }

    private var configurationView: some View {
        Form {
            if let error = daemon.errorMessage {
                Text(error).foregroundStyle(.red)
            }

            statusSection
            controlsSection
            routingSection
            sourceRulesSection
            quietHoursSection
            aiSection
            macSection
            panelSection
            testSection
            mqttSection

            Section {
                Button("Save notification configuration") {
                    save()
                }
                .disabled(daemon.isBusy || !form.didLoadConfiguration)
            }
        }
        .formStyle(.grouped)
    }

    private var statusSection: some View {
        Section("Status") {
            let summary = daemon.status?.notificationSummary
            LabeledContent(
                "Service", value: NotificationPresentation.serviceHealth(summary).label)
            if let summary {
                LabeledContent(
                    "Critical",
                    value: NotificationPresentation.activeCriticalLabel(
                        summary.engine.activeCriticalCount))
                LabeledContent("MQTT", value: summary.mqtt.displayName)
                LabeledContent("This Mac", value: summary.mac.displayName)
                LabeledContent(
                    "NSPanel",
                    value: NotificationPresentation.panelStatus(
                        availability: summary.panel,
                        tokenPresent: summary.panelTokenPresent))
            } else {
                Text("Notification service state has not been confirmed by the daemon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controlsSection: some View {
        Section("Core") {
            Toggle("Enable notifications", isOn: configurationBinding.enabled)
            Toggle("Accept MQTT ingress", isOn: configurationBinding.mqttIngressEnabled)
            Toggle(
                "Accept Home Assistant acknowledgements",
                isOn: configurationBinding.mqttAcknowledgementEnabled)
            Text("Remote configuration and login operations are never exposed over MQTT.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var routingSection: some View {
        Section("Global rule") {
            NotificationRuleEditor(rule: configurationBinding.globalRule)
        }
    }

    @ViewBuilder
    private var sourceRulesSection: some View {
        Section("Sources") {
            let sources = (daemon.status?.notificationSummary?.engine.knownSources ?? [])
                .sorted { $0.rawValue < $1.rawValue }
            if sources.isEmpty {
                Text("Sources appear after the first accepted event.")
                    .foregroundStyle(.secondary)
            }
            ForEach(sources, id: \.rawValue) { source in
                DisclosureGroup {
                    Toggle(
                        "Use a custom rule",
                        isOn: sourceOverrideEnabled(source)
                    )
                    if configuration.sourceRules[source] != nil {
                        NotificationRuleEditor(
                            rule: sourceRule(source),
                            includesQuietHours: true)
                    }
                } label: {
                    VStack(alignment: .leading) {
                        Text(source.rawValue)
                        Text(
                            NotificationPresentation.ruleLabel(
                                hasOverride: configuration.sourceRules[source] != nil)
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var quietHoursSection: some View {
        Section("Daily quiet hours") {
            Toggle("Enable quiet hours", isOn: quietHoursEnabled)
            if configuration.globalRule.quietHours != nil {
                DatePicker(
                    "Start", selection: quietHoursDate(isStart: true),
                    displayedComponents: .hourAndMinute)
                DatePicker(
                    "End", selection: quietHoursDate(isStart: false),
                    displayedComponents: .hourAndMinute)
                Text("Critical alerts bypass quiet hours only when enabled in their route.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var aiSection: some View {
        Section("AI sensor transitions") {
            Toggle(
                "Authorization required and restored",
                isOn: configurationBinding.ai.authorizationTransitionsEnabled)
            Toggle(
                "Confirmed quota resets",
                isOn: configurationBinding.ai.quotaResetTransitionsEnabled)
            Toggle("Repeated collection failures", isOn: failureThresholdEnabled)
            if configuration.ai.consecutiveFailureCount != nil {
                Stepper(
                    "Notify after \(configuration.ai.consecutiveFailureCount ?? 1) failures",
                    value: failureThreshold,
                    in: 1...20)
            }

            DisclosureGroup("Quota thresholds") {
                ForEach(configuration.ai.quotaThresholds.indices, id: \.self) { index in
                    HStack {
                        TextField("Account", text: quotaAccount(index))
                        TextField(
                            "Quota",
                            text: configurationBinding.ai.quotaThresholds[index].quotaID)
                        Stepper(
                            "\(configuration.ai.quotaThresholds[index].remainingPercent, specifier: "%.0f")%",
                            value: configurationBinding.ai.quotaThresholds[index].remainingPercent,
                            in: 0...100)
                        Button("Remove", role: .destructive) {
                            configuration.ai.quotaThresholds.remove(at: index)
                        }
                    }
                }
                Button("Add quota threshold") { addQuotaThreshold() }
                    .disabled(daemon.status?.accounts.isEmpty != false)
            }

            DisclosureGroup("Balance thresholds") {
                ForEach(configuration.ai.balanceThresholds.indices, id: \.self) { index in
                    HStack {
                        TextField("Account", text: balanceAccount(index))
                        TextField(
                            "Currency",
                            text: configurationBinding.ai.balanceThresholds[index].currency
                        )
                        .frame(width: 80)
                        TextField("Amount", text: balanceAmount(index))
                            .frame(width: 110)
                        Button("Remove", role: .destructive) {
                            configuration.ai.balanceThresholds.remove(at: index)
                        }
                    }
                }
                Button("Add balance threshold") { addBalanceThreshold() }
                    .disabled(daemon.status?.accounts.isEmpty != false)
            }
        }
    }

    private var macSection: some View {
        Section("This Mac") {
            Text(NotificationPresentation.authorizationMessage(macNotifications.authorization))
                .foregroundStyle(
                    macNotifications.authorization == .denied ? .red : .secondary)
            HStack {
                Button("Request permission") {
                    Task { _ = await macNotifications.requestAuthorization() }
                }
                .disabled(macNotifications.authorization == .authorized)
                Button("Open System Settings…") {
                    if let url = URL(
                        string:
                            "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private var panelSection: some View {
        Section("SONOFF NSPanel Pro 120") {
            Toggle("Configure panel", isOn: panelEnabled)
            if configuration.panel != nil {
                TextField("Local host or IPv4", text: panelHost)
                TextField("Port", value: panelPort, format: .number)
                HStack {
                    Button("Pair") { Task { await daemon.pairNSPanel() } }
                    Button("Clear token", role: .destructive) {
                        Task { await daemon.clearNSPanelToken() }
                    }
                }
                .disabled(daemon.isBusy)
                if let pairing = daemon.panelPairingStatus {
                    Text(NotificationPresentation.pairingInstructions(pairing))
                        .font(.caption)
                }
            }
        }
    }

    private var testSection: some View {
        Section("Channel tests") {
            HStack {
                ForEach(NotificationPresentation.testActions) { action in
                    Button(action.title) {
                        Task { await daemon.testNotificationChannel(action.channel) }
                    }
                    .disabled(daemon.isBusy)
                }
            }
            Text("Each button invokes only the named finite channel operation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var mqttSection: some View {
        Section("MQTT contract") {
            Text("Ingress: <prefix>/notifications/in/<source>")
            Text("Acknowledgement: <prefix>/notifications/ack")
            Text(
                "Allow publishers only on ingress and acknowledgement. MacTower's daemon needs publish access to notification state, events, panel state, availability, and Home Assistant discovery."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func applyDaemonConfiguration(_ summary: NotificationSummary?) {
        guard let summary else { return }
        configuration = summary.engine.configuration
        form.didLoadConfiguration = true
    }

    private func save() {
        do {
            let validated = try configuration.validated()
            Task { await daemon.saveNotificationConfiguration(validated) }
        } catch {
            daemon.errorMessage = "Invalid notification configuration."
        }
    }

    private func sourceOverrideEnabled(_ source: NotificationSourceID) -> Binding<Bool> {
        Binding(
            get: { configuration.sourceRules[source] != nil },
            set: { enabled in
                if enabled {
                    configuration.sourceRules[source] = configuration.globalRule
                } else {
                    configuration.sourceRules.removeValue(forKey: source)
                }
            })
    }

    private func sourceRule(_ source: NotificationSourceID) -> Binding<NotificationRule> {
        Binding(
            get: { configuration.sourceRules[source] ?? configuration.globalRule },
            set: { configuration.sourceRules[source] = $0 })
    }

    private var quietHoursEnabled: Binding<Bool> {
        Binding(
            get: { configuration.globalRule.quietHours != nil },
            set: { enabled in
                configuration.globalRule.quietHours =
                    enabled ? try? QuietHours(startMinute: 22 * 60, endMinute: 7 * 60) : nil
            })
    }

    private func quietHoursDate(isStart: Bool) -> Binding<Date> {
        Binding(
            get: {
                let minute =
                    isStart
                    ? configuration.globalRule.quietHours?.startMinute ?? 22 * 60
                    : configuration.globalRule.quietHours?.endMinute ?? 7 * 60
                return Calendar.current.date(
                    from: DateComponents(
                        year: 2001, month: 1, day: 1, hour: minute / 60,
                        minute: minute % 60)) ?? Date(timeIntervalSince1970: 0)
            },
            set: { date in
                guard let current = configuration.globalRule.quietHours else { return }
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                configuration.globalRule.quietHours = try? QuietHours(
                    startMinute: isStart ? minute : current.startMinute,
                    endMinute: isStart ? current.endMinute : minute)
            })
    }

    private var failureThresholdEnabled: Binding<Bool> {
        Binding(
            get: { configuration.ai.consecutiveFailureCount != nil },
            set: { configuration.ai.consecutiveFailureCount = $0 ? 3 : nil })
    }

    private var failureThreshold: Binding<Int> {
        Binding(
            get: { configuration.ai.consecutiveFailureCount ?? 3 },
            set: { configuration.ai.consecutiveFailureCount = $0 })
    }

    private var panelEnabled: Binding<Bool> {
        Binding(
            get: { configuration.panel != nil },
            set: { configuration.panel = $0 ? NSPanelConfiguration(host: "192.168.1.2") : nil })
    }

    private var panelHost: Binding<String> {
        Binding(
            get: { configuration.panel?.host ?? "" },
            set: {
                configuration.panel = NSPanelConfiguration(
                    host: $0, port: configuration.panel?.port ?? 8081)
            })
    }

    private var panelPort: Binding<Int> {
        Binding(
            get: { configuration.panel?.port ?? 8081 },
            set: {
                configuration.panel = NSPanelConfiguration(
                    host: configuration.panel?.host ?? "", port: $0)
            })
    }

    private func quotaAccount(_ index: Int) -> Binding<String> {
        Binding(
            get: { configuration.ai.quotaThresholds[index].accountID.rawValue },
            set: { configuration.ai.quotaThresholds[index].accountID = AccountID($0) })
    }

    private func balanceAccount(_ index: Int) -> Binding<String> {
        Binding(
            get: { configuration.ai.balanceThresholds[index].accountID.rawValue },
            set: { configuration.ai.balanceThresholds[index].accountID = AccountID($0) })
    }

    private func balanceAmount(_ index: Int) -> Binding<String> {
        Binding(
            get: { configuration.ai.balanceThresholds[index].amount.value },
            set: { value in
                if let amount = try? DecimalString(value) {
                    configuration.ai.balanceThresholds[index].amount = amount
                }
            })
    }

    private func addQuotaThreshold() {
        guard let account = daemon.status?.accounts.first else { return }
        configuration.ai.quotaThresholds.append(
            AIQuotaNotificationThreshold(
                accountID: account.id, quotaID: "weekly", remainingPercent: 20))
    }

    private func addBalanceThreshold() {
        guard let account = daemon.status?.accounts.first,
            let amount = try? DecimalString("10")
        else { return }
        configuration.ai.balanceThresholds.append(
            AIBalanceNotificationThreshold(
                accountID: account.id, currency: "USD", amount: amount))
    }
}

private struct NotificationRuleEditor: View {
    @Binding var rule: NotificationRule
    var includesQuietHours = false

    var body: some View {
        if includesQuietHours {
            Toggle("Override quiet hours", isOn: quietHoursEnabled)
            if rule.quietHours != nil {
                DatePicker(
                    "Quiet start", selection: quietHoursDate(isStart: true),
                    displayedComponents: .hourAndMinute)
                DatePicker(
                    "Quiet end", selection: quietHoursDate(isStart: false),
                    displayedComponents: .hourAndMinute)
            }
        }
        ForEach(NotificationSeverity.allCases, id: \.rawValue) { severity in
            DisclosureGroup(severity.displayName) {
                let route = routeBinding(severity)
                HStack {
                    ForEach(NotificationChannel.allCases, id: \.rawValue) { channel in
                        Toggle(channel.displayName, isOn: channelBinding(route, channel))
                    }
                }
                Toggle("Wake panel", isOn: route.wakePanel)
                    .disabled(!route.wrappedValue.channels.contains(.panel))
                Toggle("Play panel sound", isOn: soundEnabled(route))
                    .disabled(!route.wrappedValue.channels.contains(.panel))
                if route.wrappedValue.panelSound != nil {
                    Picker("Sound", selection: soundName(route)) {
                        ForEach(NSPanelSoundName.allCases, id: \.rawValue) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    Stepper(
                        "Volume: \(route.wrappedValue.panelSound?.volume ?? 50)%",
                        value: soundVolume(route), in: 0...100)
                    Stepper(
                        "Countdown: \(route.wrappedValue.panelSound?.countdownSeconds ?? 0)s",
                        value: soundCountdown(route), in: 0...1_799)
                }
                Stepper(
                    "Cooldown: \(route.wrappedValue.cooldownSeconds)s",
                    value: route.cooldownSeconds, in: 0...86_400, step: 60)
                if severity == .critical {
                    Toggle("Repeat until acknowledged", isOn: reminderEnabled(route))
                    if route.wrappedValue.reminderSeconds != nil {
                        Stepper(
                            "Reminder: \(route.wrappedValue.reminderSeconds ?? 300)s",
                            value: reminderSeconds(route), in: 60...86_400, step: 60)
                    }
                    Toggle("Bypass quiet hours", isOn: route.bypassQuietHours)
                }
            }
        }
    }

    private func routeBinding(_ severity: NotificationSeverity) -> Binding<NotificationRoute> {
        Binding(
            get: { rule.deliveries[severity] ?? NotificationRoute(channels: []) },
            set: { rule.deliveries[severity] = $0 })
    }

    private func channelBinding(
        _ route: Binding<NotificationRoute>,
        _ channel: NotificationChannel
    ) -> Binding<Bool> {
        Binding(
            get: { route.wrappedValue.channels.contains(channel) },
            set: { enabled in
                if enabled {
                    route.wrappedValue.channels.insert(channel)
                } else {
                    route.wrappedValue.channels.remove(channel)
                    if channel == .panel {
                        route.wrappedValue.wakePanel = false
                        route.wrappedValue.panelSound = nil
                    }
                }
            })
    }

    private func soundEnabled(_ route: Binding<NotificationRoute>) -> Binding<Bool> {
        Binding(
            get: { route.wrappedValue.panelSound != nil },
            set: {
                route.wrappedValue.panelSound =
                    $0 ? NSPanelSound(name: .alert1, volume: 50, countdownSeconds: 0) : nil
            })
    }

    private func soundName(_ route: Binding<NotificationRoute>) -> Binding<NSPanelSoundName> {
        Binding(
            get: { route.wrappedValue.panelSound?.name ?? .alert1 },
            set: { name in
                let old = route.wrappedValue.panelSound
                route.wrappedValue.panelSound = NSPanelSound(
                    name: name, volume: old?.volume ?? 50,
                    countdownSeconds: old?.countdownSeconds ?? 0)
            })
    }

    private func soundVolume(_ route: Binding<NotificationRoute>) -> Binding<Int> {
        Binding(
            get: { route.wrappedValue.panelSound?.volume ?? 50 },
            set: { volume in
                let old = route.wrappedValue.panelSound
                route.wrappedValue.panelSound = NSPanelSound(
                    name: old?.name ?? .alert1, volume: volume,
                    countdownSeconds: old?.countdownSeconds ?? 0)
            })
    }

    private func soundCountdown(_ route: Binding<NotificationRoute>) -> Binding<Int> {
        Binding(
            get: { route.wrappedValue.panelSound?.countdownSeconds ?? 0 },
            set: { countdown in
                let old = route.wrappedValue.panelSound
                route.wrappedValue.panelSound = NSPanelSound(
                    name: old?.name ?? .alert1, volume: old?.volume ?? 50,
                    countdownSeconds: countdown)
            })
    }

    private func reminderEnabled(_ route: Binding<NotificationRoute>) -> Binding<Bool> {
        Binding(
            get: { route.wrappedValue.reminderSeconds != nil },
            set: { route.wrappedValue.reminderSeconds = $0 ? 300 : nil })
    }

    private func reminderSeconds(_ route: Binding<NotificationRoute>) -> Binding<Int> {
        Binding(
            get: { route.wrappedValue.reminderSeconds ?? 300 },
            set: { route.wrappedValue.reminderSeconds = $0 })
    }

    private var quietHoursEnabled: Binding<Bool> {
        Binding(
            get: { rule.quietHours != nil },
            set: { enabled in
                rule.quietHours =
                    enabled ? try? QuietHours(startMinute: 22 * 60, endMinute: 7 * 60) : nil
            })
    }

    private func quietHoursDate(isStart: Bool) -> Binding<Date> {
        Binding(
            get: {
                let minute =
                    isStart
                    ? rule.quietHours?.startMinute ?? 22 * 60
                    : rule.quietHours?.endMinute ?? 7 * 60
                return Calendar.current.date(
                    from: DateComponents(
                        year: 2001, month: 1, day: 1, hour: minute / 60,
                        minute: minute % 60)) ?? Date(timeIntervalSince1970: 0)
            },
            set: { date in
                guard let current = rule.quietHours else { return }
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                rule.quietHours = try? QuietHours(
                    startMinute: isStart ? minute : current.startMinute,
                    endMinute: isStart ? current.endMinute : minute)
            })
    }
}

extension NotificationChannelAvailability {
    fileprivate var displayName: String {
        switch self {
        case .disabled: "Disabled"
        case .unavailable: "Unavailable"
        case .available: "Available"
        }
    }
}

extension NotificationSeverity {
    fileprivate var displayName: String { rawValue.capitalized }
}

extension NotificationChannel {
    fileprivate var displayName: String {
        switch self {
        case .mqtt: "MQTT"
        case .mac: "Mac"
        case .panel: "Panel"
        }
    }
}

private enum NotificationSettingsSection: String, CaseIterable, Identifiable {
    case configuration = "Configuration"
    case history = "History"
    var id: String { rawValue }
}

@MainActor
private final class NotificationSettingsFormModel: ObservableObject {
    @Published var configuration = NotificationConfiguration.disabled
    @Published var section = NotificationSettingsSection.configuration
    @Published var didLoadConfiguration = false
}
