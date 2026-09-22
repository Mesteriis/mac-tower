import Combine
import Foundation
import MacTowerCore
import UserNotifications

enum MacNotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

struct MacNotificationRequest: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let categoryIdentifier: String?
}

protocol UserNotificationCenterServing: Sendable {
    func authorizationStatus() async -> MacNotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func add(_ request: MacNotificationRequest) async throws
    func remove(identifier: String) async
}

protocol NotificationAcknowledging: Sendable {
    func acknowledgeNotification(eventID: UUID) async
}

@MainActor
final class MacNotificationController: ObservableObject {
    nonisolated static let categoryIdentifier = "MACTOWER_CRITICAL"
    nonisolated static let acknowledgeActionIdentifier = "MACTOWER_ACKNOWLEDGE"

    @Published private(set) var authorization: MacNotificationAuthorization = .notDetermined

    private let center: any UserNotificationCenterServing
    private let acknowledger: any NotificationAcknowledging
    private var handledActions = Set<UUID>()

    init(
        center: any UserNotificationCenterServing,
        acknowledger: any NotificationAcknowledging
    ) {
        self.center = center
        self.acknowledger = acknowledger
        if let system = center as? SystemUserNotificationCenter {
            system.setActionHandler { [weak self] action, identifier in
                Task { @MainActor in
                    await self?.handleAction(
                        actionIdentifier: action,
                        requestIdentifier: identifier
                    )
                }
            }
        }
    }

    func refreshAuthorization() async {
        authorization = await center.authorizationStatus()
    }

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization()
            await refreshAuthorization()
            return granted
        } catch {
            await refreshAuthorization()
            return false
        }
    }

    func deliver(_ delivery: MacNotificationDelivery) async -> NotificationDeliveryState {
        let status = await center.authorizationStatus()
        authorization = status
        guard status == .authorized else { return .failed }
        do {
            try await center.add(
                MacNotificationRequest(
                    identifier: delivery.eventID.uuidString,
                    title: delivery.title,
                    body: delivery.message,
                    categoryIdentifier: delivery.severity == .critical
                        ? Self.categoryIdentifier : nil
                ))
            return .handedOff
        } catch {
            return .failed
        }
    }

    func remove(eventID: UUID) async {
        await center.remove(identifier: eventID.uuidString)
    }

    func handleAction(actionIdentifier: String, requestIdentifier: String) async {
        guard actionIdentifier == Self.acknowledgeActionIdentifier,
            let eventID = UUID(uuidString: requestIdentifier),
            handledActions.insert(eventID).inserted
        else { return }
        await acknowledger.acknowledgeNotification(eventID: eventID)
    }
}

final class SystemUserNotificationCenter: NSObject, UserNotificationCenterServing,
    UNUserNotificationCenterDelegate, @unchecked Sendable
{
    private let center = UNUserNotificationCenter.current()
    private let lock = NSLock()
    private var actionHandler: (@Sendable (String, String) -> Void)?

    override init() {
        super.init()
        let action = UNNotificationAction(
            identifier: MacNotificationController.acknowledgeActionIdentifier,
            title: "Acknowledge"
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: MacNotificationController.categoryIdentifier,
                actions: [action],
                intentIdentifiers: []
            )
        ])
        center.delegate = self
    }

    func setActionHandler(_ handler: @escaping @Sendable (String, String) -> Void) {
        lock.withLock { actionHandler = handler }
    }

    func authorizationStatus() async -> MacNotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized, .provisional, .ephemeral: .authorized
        @unknown default: .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func add(_ request: MacNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        if let categoryIdentifier = request.categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }
        try await center.add(
            UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil))
    }

    func remove(identifier: String) async {
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let handler = lock.withLock { actionHandler }
        handler?(response.actionIdentifier, response.notification.request.identifier)
    }
}
