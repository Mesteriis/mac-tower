import Foundation

public struct NotificationPolicyDecision: Equatable, Sendable {
    public let channels: Set<NotificationChannel>
    public let suppressedChannels: Set<NotificationChannel>
    public let wakePanel: Bool
    public let panelSound: NSPanelSound?
    public let cooldownSeconds: Int
    public let reminderSeconds: Int?

    public init(
        channels: Set<NotificationChannel>,
        suppressedChannels: Set<NotificationChannel> = [],
        wakePanel: Bool = false,
        panelSound: NSPanelSound? = nil,
        cooldownSeconds: Int = 0,
        reminderSeconds: Int? = nil
    ) {
        self.channels = channels
        self.suppressedChannels = suppressedChannels
        self.wakePanel = wakePanel
        self.panelSound = panelSound
        self.cooldownSeconds = cooldownSeconds
        self.reminderSeconds = reminderSeconds
    }

    public static let silent = NotificationPolicyDecision(channels: [])
}

public struct NotificationPolicyEvaluator: Sendable {
    public init() {}

    public func evaluate(
        _ event: NotificationEvent,
        configuration: NotificationConfiguration,
        now: Date,
        calendar: Calendar
    ) -> NotificationPolicyDecision {
        guard configuration.enabled else { return .silent }
        let rule = configuration.sourceRules[event.sourceID] ?? configuration.globalRule
        guard let route = rule.deliveries[event.severity] else { return .silent }

        if rule.quietHours?.contains(now, calendar: calendar) == true,
            !route.bypassQuietHours
        {
            return NotificationPolicyDecision(
                channels: [],
                suppressedChannels: route.channels,
                cooldownSeconds: route.cooldownSeconds,
                reminderSeconds: route.reminderSeconds
            )
        }

        return NotificationPolicyDecision(
            channels: route.channels,
            wakePanel: route.wakePanel,
            panelSound: route.panelSound,
            cooldownSeconds: route.cooldownSeconds,
            reminderSeconds: route.reminderSeconds
        )
    }
}
