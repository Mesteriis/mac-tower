import Foundation
import MacTowerCore
import MacTowerPowerControl

final class DaemonXPCServer: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private let controller: ManagementController
    private let windowControl: WindowControlService
    private let powerControl: PowerControlService
    private let notificationService: NotificationService?
    private let ownerUID: uid_t
    private let appRequirement: String

    init(
        controller: ManagementController,
        windowControl: WindowControlService,
        powerControl: PowerControlService,
        notificationService: NotificationService? = nil,
        trustManifestURL: URL
    ) throws {
        let data = try Data(contentsOf: trustManifestURL)
        let manifest = try JSONDecoder().decode(TrustManifest.self, from: data)
        _ = try manifest.daemonRequirement()
        ownerUID = manifest.ownerUID
        self.controller = controller
        self.windowControl = windowControl
        self.powerControl = powerControl
        self.notificationService = notificationService
        appRequirement = try manifest.appRequirement()
        listener = NSXPCListener(machServiceName: "dev.mactower.daemon")
        super.init()
        listener.delegate = self
        listener.setConnectionCodeSigningRequirement(appRequirement)
    }

    func start() {
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
        -> Bool
    {
        guard connection.effectiveUserIdentifier == ownerUID else { return false }
        let peer = WindowAgentPeer(connection: connection)
        let service = ManagementXPCService(
            handler: DaemonManagementHandler(
                controller: controller,
                power: powerControl,
                notifications: notificationService
            ),
            windowControl: windowControl,
            notificationService: notificationService,
            peer: peer
        )
        connection.exportedInterface = NSXPCInterface(with: MacTowerDaemonXPCProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: MacTowerWindowAgentXPCProtocol.self)
        connection.setCodeSigningRequirement(appRequirement)
        connection.exportedObject = service
        let router = windowControl.router
        let notificationService = self.notificationService
        let lost: @Sendable () -> Void = {
            peer.invalidate()
            Task {
                await router.disconnectAgent(id: peer.id)
                await notificationService?.unregisterUserAgent(id: peer.id)
            }
        }
        connection.invalidationHandler = lost
        connection.interruptionHandler = lost
        connection.resume()
        return true
    }
}

private final class ManagementXPCService: NSObject, MacTowerDaemonXPCProtocol, @unchecked Sendable {
    private let handler: DaemonManagementHandler
    private let windowControl: WindowControlService
    private let notificationService: NotificationService?
    private let peer: WindowAgentPeer

    init(
        handler: DaemonManagementHandler,
        windowControl: WindowControlService,
        notificationService: NotificationService?,
        peer: WindowAgentPeer
    ) {
        self.handler = handler
        self.windowControl = windowControl
        self.notificationService = notificationService
        self.peer = peer
    }

    func updateWindowAgent(
        _ snapshot: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void
    ) {
        Task {
            do {
                guard snapshot.count <= 65_536, peer.isActive else {
                    throw ManagementControllerError.invalidRequest
                }
                let value = try JSONDecoder().decode(WindowAgentSnapshot.self, from: snapshot)
                try await windowControl.router.updateAgent(
                    id: peer.id, snapshot: value,
                    execute: { [peer] request, completion in peer.move(request, reply: completion)
                    },
                    cancel: { [peer] in peer.cancel() }
                )
                guard peer.isActive else {
                    await windowControl.router.disconnectAgent(id: peer.id)
                    await notificationService?.unregisterUserAgent(id: peer.id)
                    throw ManagementControllerError.invalidRequest
                }
                await notificationService?.registerUserAgent(peer)
                reply(try JSONEncoder().encode(await windowControl.status()), nil)
            } catch { reply(nil, "window_agent_rejected") }
        }
    }

    func setWindowControlEnabled(
        _ enabled: Bool, withReply reply: @escaping @Sendable (Data?, String?) -> Void
    ) {
        Task {
            do {
                reply(try JSONEncoder().encode(try await windowControl.setEnabled(enabled)), nil)
            } catch { reply(nil, "window_control_update_failed") }
        }
    }

    func perform(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data?, String?) -> Void
    ) {
        Task {
            do {
                let result = try await handle(request)
                reply(result, nil)
            } catch {
                reply(nil, "request_failed")
            }
        }
    }

    private func handle(_ data: Data) async throws -> Data {
        try await handler.handle(data)
    }
}

private final class WindowAgentPeer: NotificationUserAgent, @unchecked Sendable {
    let id = UUID()
    private weak var connection: NSXPCConnection?
    private let lock = NSLock()
    private var active = true
    private var notificationReplies: [UUID: (NotificationDeliveryState) -> Void] = [:]

    init(connection: NSXPCConnection) { self.connection = connection }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func invalidate() {
        lock.lock()
        active = false
        let replies = Array(notificationReplies.values)
        notificationReplies.removeAll()
        lock.unlock()
        for reply in replies { reply(.failed) }
    }

    func cancel() {
        guard isActive else { return }
        (connection?.remoteObjectProxyWithErrorHandler { _ in } as? MacTowerWindowAgentXPCProtocol)?
            .cancelRemoteWindowCommands()
    }

    func move(_ request: WindowMoveRequest, reply: @escaping @Sendable (WindowMoveResult) -> Void) {
        let unavailable = WindowMoveResult(
            requestID: request.id, displayID: request.displayID, code: .unavailable)
        guard isActive, let connection, let data = try? JSONEncoder().encode(request),
            let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in reply(unavailable) })
                as? MacTowerWindowAgentXPCProtocol
        else {
            reply(unavailable)
            return
        }
        proxy.moveActiveWindow(data) { data, error in
            guard error == nil, let data, data.count <= 8_192,
                let result = try? JSONDecoder().decode(WindowMoveResult.self, from: data)
            else {
                reply(unavailable)
                return
            }
            reply(result)
        }
    }

    func deliver(_ request: MacNotificationDelivery) async -> NotificationDeliveryState {
        guard let data = try? JSONEncoder().encode(request), data.count <= 16_384 else {
            return .failed
        }
        return await withCheckedContinuation { continuation in
            let replyID = UUID()
            guard registerNotificationReply(replyID, continuation: continuation) else { return }
            guard let connection,
                let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
                    self?.finishNotificationReply(replyID, state: .failed)
                }) as? MacTowerWindowAgentXPCProtocol
            else {
                finishNotificationReply(replyID, state: .failed)
                return
            }
            proxy.deliverUserNotification(data) { [weak self] data, error in
                guard error == nil, let data, data.count <= 4_096,
                    let state = try? JSONDecoder().decode(
                        NotificationDeliveryState.self,
                        from: data
                    )
                else {
                    self?.finishNotificationReply(replyID, state: .failed)
                    return
                }
                self?.finishNotificationReply(replyID, state: state)
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.finishNotificationReply(replyID, state: .failed)
            }
        }
    }

    func remove(eventID: UUID) async {
        guard isActive, let connection,
            let data = try? JSONEncoder().encode(eventID), data.count <= 16_384,
            let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in })
                as? MacTowerWindowAgentXPCProtocol
        else { return }
        proxy.removeUserNotification(data) { _, _ in }
    }

    private func registerNotificationReply(
        _ id: UUID,
        continuation: CheckedContinuation<NotificationDeliveryState, Never>
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active else {
            continuation.resume(returning: .failed)
            return false
        }
        notificationReplies[id] = { state in continuation.resume(returning: state) }
        return true
    }

    private func finishNotificationReply(_ id: UUID, state: NotificationDeliveryState) {
        lock.lock()
        let reply = notificationReplies.removeValue(forKey: id)
        lock.unlock()
        reply?(state)
    }
}
