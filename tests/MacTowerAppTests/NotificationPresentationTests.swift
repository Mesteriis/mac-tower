import MacTowerCore
import Testing

@testable import MacTowerApp

@Suite("Notification presentation")
@MainActor
struct NotificationPresentationTests {
    @Test("Unknown service is not rendered healthy")
    func unknownService() {
        #expect(NotificationPresentation.serviceHealth(nil) == .unknown)
        #expect(!NotificationPresentation.serviceHealth(nil).isHealthy)
    }

    @Test("Missing panel token differs from an offline panel")
    func panelState() {
        #expect(
            NotificationPresentation.panelStatus(
                availability: .available, tokenPresent: false) == "Not paired")
        #expect(
            NotificationPresentation.panelStatus(
                availability: .unavailable, tokenPresent: true) == "Offline")
    }

    @Test("Handed off never claims a notification was read")
    func deliveryState() {
        let label = NotificationPresentation.deliveryLabel(.handedOff)
        #expect(label == "Handed off")
        #expect(!label.lowercased().contains("read"))
    }

    @Test("Denied Notification Center permission is actionable")
    func deniedPermission() {
        let message = NotificationPresentation.authorizationMessage(.denied)
        #expect(message.contains("System Settings"))
        #expect(message.contains("allow"))
    }

    @Test("Active critical count uses a finite pluralized label")
    func activeCount() {
        #expect(NotificationPresentation.activeCriticalLabel(0) == "No active critical alerts")
        #expect(NotificationPresentation.activeCriticalLabel(1) == "1 active critical alert")
        #expect(NotificationPresentation.activeCriticalLabel(2) == "2 active critical alerts")
    }

    @Test("Source rules explain inheritance")
    func inheritance() {
        #expect(NotificationPresentation.ruleLabel(hasOverride: false) == "Inherits global rule")
        #expect(NotificationPresentation.ruleLabel(hasOverride: true) == "Custom rule")
    }

    @Test("Pairing press-Done state names the required physical step")
    func pairing() {
        #expect(NotificationPresentation.pairingInstructions(.pressDone).contains("Done"))
        #expect(NotificationPresentation.pairingInstructions(.paired) == "Panel paired")
    }

    @Test("Every explicit channel test maps to one finite daemon operation")
    func channelTests() {
        let actions = NotificationPresentation.testActions
        #expect(actions.count == NotificationTestChannel.allCases.count)
        #expect(Set(actions.map(\.channel)) == Set(NotificationTestChannel.allCases))
        #expect(Set(actions.map(\.title)).count == actions.count)
    }
}
