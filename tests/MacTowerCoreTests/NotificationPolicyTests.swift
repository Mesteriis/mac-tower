import Foundation
import Testing

@testable import MacTowerCore

@Suite("Notification policy")
struct NotificationPolicyTests {
    @Test("Unknown sources inherit the global rule and overrides replace it")
    func unknownSourceUsesGlobalAndOverrideReplacesIt() throws {
        let source = try NotificationSourceID(validating: "weather.outdoor")
        let global = NotificationRule(
            deliveries: [.warning: NotificationRoute(channels: [.mqtt])])
        var configuration = NotificationConfiguration(enabled: true, globalRule: global)

        let inherited = NotificationPolicyEvaluator().evaluate(
            event(.warning, source),
            configuration: try configuration.validated(),
            now: date("2026-09-22T12:00:00Z"),
            calendar: utcCalendar
        )
        #expect(inherited.channels == [.mqtt])
        #expect(inherited.suppressedChannels.isEmpty)

        configuration.sourceRules[source] = NotificationRule(
            deliveries: [
                .warning: NotificationRoute(channels: [.mac, .panel], wakePanel: true)
            ])
        let overridden = NotificationPolicyEvaluator().evaluate(
            event(.warning, source),
            configuration: try configuration.validated(),
            now: date("2026-09-22T12:00:00Z"),
            calendar: utcCalendar
        )
        #expect(overridden.channels == [.mac, .panel])
        #expect(overridden.wakePanel)
    }

    @Test("Missing severity entries never imply a route")
    func missingSeverityIsSilent() throws {
        let source = try NotificationSourceID(validating: "weather")
        let configuration = try NotificationConfiguration(
            enabled: true,
            globalRule: NotificationRule(
                deliveries: [.critical: NotificationRoute(channels: [.mqtt])])
        ).validated()

        let decision = NotificationPolicyEvaluator().evaluate(
            event(.warning, source),
            configuration: configuration,
            now: date("2026-09-22T12:00:00Z"),
            calendar: utcCalendar
        )
        #expect(decision.channels.isEmpty)
        #expect(decision.suppressedChannels.isEmpty)
    }

    @Test("Disabled configuration suppresses every route")
    func disabledConfigurationIsSilent() throws {
        let source = try NotificationSourceID(validating: "source")
        let configuration = try NotificationConfiguration(
            enabled: false,
            globalRule: NotificationRule(
                deliveries: [.critical: NotificationRoute(channels: [.mqtt, .mac, .panel])])
        ).validated()

        let decision = NotificationPolicyEvaluator().evaluate(
            event(.critical, source),
            configuration: configuration,
            now: date("2026-09-22T12:00:00Z"),
            calendar: utcCalendar
        )
        #expect(decision.channels.isEmpty)
        #expect(decision.suppressedChannels.isEmpty)
    }

    @Test("Overnight quiet hours suppress delivery unless bypass is explicit")
    func overnightQuietHoursAndCriticalBypass() throws {
        let source = try NotificationSourceID(validating: "security")
        let quiet = try QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
        let warning = NotificationRoute(channels: [.mac, .panel], wakePanel: true)
        let critical = NotificationRoute(
            channels: [.mac, .panel], wakePanel: true, bypassQuietHours: true)
        let configuration = try NotificationConfiguration(
            enabled: true,
            globalRule: NotificationRule(
                deliveries: [.warning: warning, .critical: critical],
                quietHours: quiet
            )
        ).validated()
        let madrid = calendar(timeZone: "Europe/Madrid")

        let quietWarning = NotificationPolicyEvaluator().evaluate(
            event(.warning, source),
            configuration: configuration,
            now: date("2026-09-22T21:30:00Z"),
            calendar: madrid
        )
        #expect(quietWarning.channels.isEmpty)
        #expect(quietWarning.suppressedChannels == [.mac, .panel])
        #expect(!quietWarning.wakePanel)

        let bypassedCritical = NotificationPolicyEvaluator().evaluate(
            event(.critical, source),
            configuration: configuration,
            now: date("2026-09-22T21:30:00Z"),
            calendar: madrid
        )
        #expect(bypassedCritical.channels == [.mac, .panel])
        #expect(bypassedCritical.suppressedChannels.isEmpty)

        let midday = NotificationPolicyEvaluator().evaluate(
            event(.warning, source),
            configuration: configuration,
            now: date("2026-09-22T10:00:00Z"),
            calendar: madrid
        )
        #expect(midday.channels == [.mac, .panel])
    }

    @Test("Both repeated DST hours are evaluated by local clock components")
    func repeatedDSTHourIsQuiet() throws {
        let source = try NotificationSourceID(validating: "security")
        let configuration = try NotificationConfiguration(
            enabled: true,
            globalRule: NotificationRule(
                deliveries: [.warning: NotificationRoute(channels: [.mac])],
                quietHours: QuietHours(startMinute: 2 * 60, endMinute: 3 * 60)
            )
        ).validated()
        let madrid = calendar(timeZone: "Europe/Madrid")

        for instant in ["2026-10-25T00:30:00Z", "2026-10-25T01:30:00Z"] {
            let decision = NotificationPolicyEvaluator().evaluate(
                event(.warning, source),
                configuration: configuration,
                now: date(instant),
                calendar: madrid
            )
            #expect(decision.channels.isEmpty)
            #expect(decision.suppressedChannels == [.mac])
        }
    }

    @Test("Route validation rejects unsafe combinations and timing bounds")
    func routeValidation() {
        let sound = NSPanelSound(name: .alert1, volume: 50, countdownSeconds: 3)
        for route in [
            NotificationRoute(channels: [.mac], wakePanel: true),
            NotificationRoute(channels: [.mac], panelSound: sound),
            NotificationRoute(channels: [.panel], cooldownSeconds: -1),
            NotificationRoute(channels: [.panel], cooldownSeconds: 86_401),
            NotificationRoute(channels: [.panel], reminderSeconds: 59),
            NotificationRoute(channels: [.panel], reminderSeconds: 86_401),
            NotificationRoute(
                channels: [.panel],
                panelSound: NSPanelSound(
                    name: .alert1, volume: 101, countdownSeconds: 3)),
            NotificationRoute(
                channels: [.panel],
                panelSound: NSPanelSound(
                    name: .alert1, volume: 50, countdownSeconds: 1_800)),
        ] {
            let configuration = NotificationConfiguration(
                enabled: true,
                globalRule: NotificationRule(deliveries: [.warning: route])
            )
            #expect(throws: NotificationConfigurationError.self) {
                try configuration.validated()
            }
        }
    }

    @Test("Panel configuration accepts only explicit local hosts and valid ports")
    func panelConfigurationValidation() throws {
        for panel in [
            NSPanelConfiguration(host: "", port: 8081),
            NSPanelConfiguration(host: "example.com", port: 8081),
            NSPanelConfiguration(host: "8.8.8.8", port: 8081),
            NSPanelConfiguration(host: "panel.local", port: 0),
            NSPanelConfiguration(host: "panel.local", port: 65_536),
        ] {
            #expect(throws: NotificationConfigurationError.self) {
                try NotificationConfiguration(panel: panel).validated()
            }
        }

        #expect(
            try NotificationConfiguration(
                panel: NSPanelConfiguration(host: "192.168.1.20")
            ).validated().panel?.port == 8081)
        #expect(
            try NotificationConfiguration(
                panel: NSPanelConfiguration(host: "kitchen-panel.local")
            ).validated().panel?.host == "kitchen-panel.local")
    }

    @Test("AI thresholds are finite, exact, and disabled by default")
    func aiConfigurationValidation() throws {
        #expect(AINotificationConfiguration.disabled.quotaThresholds.isEmpty)
        #expect(AINotificationConfiguration.disabled.balanceThresholds.isEmpty)
        #expect(AINotificationConfiguration.disabled.consecutiveFailureCount == nil)

        let accountID = AccountID("deepseek-main")
        let valid = AINotificationConfiguration(
            authorizationTransitionsEnabled: true,
            quotaResetTransitionsEnabled: true,
            quotaThresholds: [
                AIQuotaNotificationThreshold(
                    accountID: accountID, quotaID: "five-hour", remainingPercent: 20)
            ],
            balanceThresholds: [
                AIBalanceNotificationThreshold(
                    accountID: accountID,
                    currency: "CNY",
                    amount: try DecimalString("10.25"))
            ],
            consecutiveFailureCount: 3
        )
        #expect(try NotificationConfiguration(ai: valid).validated().ai == valid)

        for invalid in [
            AINotificationConfiguration(consecutiveFailureCount: 0),
            AINotificationConfiguration(consecutiveFailureCount: 21),
            AINotificationConfiguration(
                quotaThresholds: [
                    AIQuotaNotificationThreshold(
                        accountID: accountID, quotaID: "five-hour", remainingPercent: 101)
                ]),
            AINotificationConfiguration(
                balanceThresholds: [
                    AIBalanceNotificationThreshold(
                        accountID: accountID,
                        currency: "bad currency",
                        amount: try DecimalString("10"))
                ]),
        ] {
            #expect(throws: NotificationConfigurationError.self) {
                try NotificationConfiguration(ai: invalid).validated()
            }
        }
    }

    private var utcCalendar: Calendar { calendar(timeZone: "UTC") }

    private func calendar(timeZone identifier: String) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: identifier)!
        return result
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func event(
        _ severity: NotificationSeverity,
        _ sourceID: NotificationSourceID
    ) -> NotificationEvent {
        NotificationEvent(
            eventID: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
            sourceID: sourceID,
            severity: severity,
            title: "Title",
            message: "Message",
            createdAt: date("2026-09-22T10:00:00Z")
        )
    }
}
