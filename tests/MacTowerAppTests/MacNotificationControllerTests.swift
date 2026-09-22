import Foundation
import MacTowerCore
import Testing

@testable import MacTowerApp

@Suite("Mac Notification Center bridge")
@MainActor
struct MacNotificationControllerTests {
    private let eventID = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!

    @Test("Denied permission fails without adding a request")
    func denied() async {
        let center = FakeNotificationCenter(status: .denied)
        let acknowledger = FakeNotificationAcknowledger()
        let controller = MacNotificationController(center: center, acknowledger: acknowledger)

        #expect(await controller.deliver(delivery()) == .failed)
        #expect(await center.requests.isEmpty)
        #expect(controller.authorization == .denied)
    }

    @Test("Stable identifiers replace requests and critical alone exposes Acknowledge")
    func stableRequests() async {
        let center = FakeNotificationCenter(status: .authorized)
        let controller = MacNotificationController(
            center: center, acknowledger: FakeNotificationAcknowledger())

        #expect(await controller.deliver(delivery(message: "<b>literal</b>")) == .handedOff)
        #expect(await controller.deliver(delivery(message: "replacement")) == .handedOff)
        #expect(
            await controller.deliver(delivery(severity: .warning, message: "warning"))
                == .handedOff)

        let requests = await center.requests
        #expect(requests[0].identifier == eventID.uuidString)
        #expect(requests[0].body == "<b>literal</b>")
        #expect(requests[0].categoryIdentifier == MacNotificationController.categoryIdentifier)
        #expect(requests[1].identifier == eventID.uuidString)
        #expect(requests[2].categoryIdentifier == nil)
    }

    @Test("Only one valid fixed action reaches daemon acknowledgement")
    func acknowledgementAction() async {
        let acknowledger = FakeNotificationAcknowledger()
        let controller = MacNotificationController(
            center: FakeNotificationCenter(status: .authorized),
            acknowledger: acknowledger
        )

        await controller.handleAction(
            actionIdentifier: "OTHER", requestIdentifier: eventID.uuidString)
        await controller.handleAction(
            actionIdentifier: MacNotificationController.acknowledgeActionIdentifier,
            requestIdentifier: "not-a-uuid"
        )
        await controller.handleAction(
            actionIdentifier: MacNotificationController.acknowledgeActionIdentifier,
            requestIdentifier: eventID.uuidString
        )
        await controller.handleAction(
            actionIdentifier: MacNotificationController.acknowledgeActionIdentifier,
            requestIdentifier: eventID.uuidString
        )

        #expect(await acknowledger.eventIDs == [eventID])
    }

    private func delivery(
        severity: NotificationSeverity = .critical,
        message: String = "Message"
    ) -> MacNotificationDelivery {
        MacNotificationDelivery(
            eventID: eventID,
            severity: severity,
            title: "Title",
            message: message
        )
    }
}

private actor FakeNotificationCenter: UserNotificationCenterServing {
    private let status: MacNotificationAuthorization
    private(set) var requests: [MacNotificationRequest] = []

    init(status: MacNotificationAuthorization) {
        self.status = status
    }

    func authorizationStatus() async -> MacNotificationAuthorization { status }
    func requestAuthorization() async throws -> Bool { status == .authorized }
    func add(_ request: MacNotificationRequest) async throws { requests.append(request) }
    func remove(identifier: String) async {}
}

private actor FakeNotificationAcknowledger: NotificationAcknowledging {
    private(set) var eventIDs: [UUID] = []
    func acknowledgeNotification(eventID: UUID) async { eventIDs.append(eventID) }
}
