import Combine
import Foundation
import MacTowerCore
import MacTowerWindowControl

/// One duplex connection belongs to the GUI process. An acknowledged heartbeat
/// grants no authority beyond the daemon's current, explicit window-control opt-in.
@MainActor
final class WindowAgentBridge: ObservableObject {
    @Published private var session = WindowBridgeSession()
    @Published private(set) var isUpdatingPreference = false
    @Published private(set) var errorMessage: String?

    private let controller: WindowController
    private let notificationController: MacNotificationController
    private var connection: NSXPCConnection?
    private var heartbeatTask: Task<Void, Never>?
    private let replies = XPCReplyLedger()
    private var remoteCommand: RemoteWindowCommand?

    var isConnected: Bool { session.isConnected }
    var remoteEnabled: Bool { session.remoteEnabled }
    private var connectionID: UUID? { session.connectionID }

    init(controller: WindowController, notificationController: MacNotificationController) {
        self.controller = controller
        self.notificationController = notificationController
    }

    func start() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.heartbeat()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        disconnect()
    }

    func setRemoteEnabled(_ enabled: Bool) async {
        guard isConnected, !isUpdatingPreference, let id = connectionID else { return }
        session.beginPreferenceChange(enabled: enabled)
        let revision = session.revision
        isUpdatingPreference = true
        errorMessage = nil
        if !enabled {
            cancelRemoteCommand(code: .cancelled)
        }
        defer { isUpdatingPreference = false }
        do {
            let status = try await send(.setEnabled(enabled), connectionID: id)
            guard connectionID == id else { return }
            apply(status, connectionID: id, revision: revision)
        } catch {
            errorMessage = "Could not update Home Assistant control. The service is unavailable."
            disconnect(expectedID: id)
        }
    }

    private func heartbeat() async {
        guard !isUpdatingPreference, !Task.isCancelled else { return }
        do {
            await controller.refresh()
            try Task.checkCancellation()
            try connectIfNeeded()
            guard let id = connectionID else { return }
            let revision = session.revision
            let snapshot = controller.snapshot
            try snapshot.validate()
            let status = try await send(
                .heartbeat(JSONEncoder().encode(snapshot)), connectionID: id)
            guard connectionID == id else { return }
            apply(status, connectionID: id, revision: revision)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Window control service is unavailable. Reconnecting…"
            disconnect()
        }
    }

    private func connectIfNeeded() throws {
        guard connection == nil else { return }
        let newConnection = try DaemonConnectionFactory.makeConnection()
        let id = UUID()
        newConnection.exportedInterface = NSXPCInterface(with: MacTowerWindowAgentXPCProtocol.self)
        newConnection.exportedObject = WindowAgentEndpoint(bridge: self, connectionID: id)
        newConnection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.disconnect(expectedID: id) }
        }
        newConnection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.disconnect(expectedID: id) }
        }
        connection = newConnection
        session.connect(id)
        newConnection.resume()
    }

    private func apply(_ status: WindowBridgeStatus, connectionID: UUID, revision: Int) {
        let previousEpoch = session.commandEpoch
        guard session.acknowledge(status, connectionID: connectionID, revision: revision) else {
            return
        }
        errorMessage = nil
        if !status.enabled || previousEpoch != session.commandEpoch {
            cancelRemoteCommand(code: .cancelled)
        }
    }

    private enum Request {
        case heartbeat(Data)
        case setEnabled(Bool)
    }

    private func send(_ request: Request, connectionID id: UUID) async throws -> WindowBridgeStatus
    {
        guard connectionID == id, let connection else { throw DaemonClientError.unavailable }
        let data = try await replies.request(
            timeout: .seconds(3),
            onTimeout: { [weak self] in self?.disconnect(expectedID: id) },
            start: { requestID in
                guard
                    let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
                        Task { @MainActor in self?.disconnect(expectedID: id) }
                    }) as? MacTowerDaemonXPCProtocol
                else {
                    disconnect(expectedID: id)
                    return
                }
                let reply: @Sendable (Data?, String?) -> Void = { [weak self] data, error in
                    Task { @MainActor in
                        guard let self, self.connectionID == id else { return }
                        if error != nil || data == nil || (data?.count ?? 0) > 4_096 {
                            self.disconnect(expectedID: id)
                        } else if let data {
                            self.replies.finish(requestID, result: .success(data))
                        }
                    }
                }
                switch request {
                case .heartbeat(let snapshot): proxy.updateWindowAgent(snapshot, withReply: reply)
                case .setEnabled(let enabled):
                    proxy.setWindowControlEnabled(enabled, withReply: reply)
                }
            }
        )
        return try JSONDecoder().decode(WindowBridgeStatus.self, from: data)
    }

    private func disconnect(expectedID: UUID? = nil) {
        if let expectedID, connectionID != expectedID { return }
        let previous = connection
        connection = nil
        session.disconnect()
        cancelRemoteCommand(code: .unavailable)
        replies.disconnect()
        previous?.invalidate()
    }

    fileprivate func moveActiveWindow(
        _ data: Data, connectionID id: UUID,
        reply: @escaping @Sendable (Data?, String?) -> Void
    ) {
        guard data.count <= 16_384,
            let request = try? JSONDecoder().decode(WindowMoveRequest.self, from: data),
            UUID(uuidString: request.displayID) != nil
        else {
            reply(nil, "invalid_command")
            return
        }
        if let rejection = session.admit(request, connectionID: id, isBusy: remoteCommand != nil) {
            respond(request, code: rejection, reply: reply)
            return
        }
        let controller = self.controller
        let command = RemoteWindowCommand(
            request: request,
            cancelOperation: { controller.cancelRemoteOperations() },
            completion: { [weak self] commandID, result in
                self?.finishRemoteCommand(commandID, result: result, reply: reply)
            }
        )
        remoteCommand = command
        command.start(
            canStart: { [weak self] in
                self?.session.permits(request, connectionID: id) == true
            },
            operation: {
                await controller.move(
                    to: request.displayID, useMenuTarget: false,
                    requestID: request.id, expectedGeneration: request.generation)
            }
        )
    }

    fileprivate func cancelRemoteCommands(connectionID id: UUID) {
        guard connectionID == id else { return }
        session.cancelRemoteCommands()
        cancelRemoteCommand(code: .cancelled)
    }

    fileprivate func deliverUserNotification(
        _ data: Data,
        connectionID id: UUID,
        reply: @escaping @Sendable (Data?, String?) -> Void
    ) async {
        guard connectionID == id, data.count <= 16_384,
            let request = try? JSONDecoder().decode(MacNotificationDelivery.self, from: data)
        else {
            reply(nil, "invalid_notification")
            return
        }
        let state = await notificationController.deliver(request)
        guard connectionID == id else {
            reply(nil, "stale_connection")
            return
        }
        guard let encoded = try? JSONEncoder().encode(state), encoded.count <= 4_096 else {
            reply(nil, "encoding_failed")
            return
        }
        reply(encoded, nil)
    }

    fileprivate func removeUserNotification(
        _ data: Data,
        connectionID id: UUID,
        reply: @escaping @Sendable (Data?, String?) -> Void
    ) async {
        guard connectionID == id, data.count <= 16_384,
            let eventID = try? JSONDecoder().decode(UUID.self, from: data)
        else {
            reply(nil, "invalid_notification")
            return
        }
        await notificationController.remove(eventID: eventID)
        guard connectionID == id else {
            reply(nil, "stale_connection")
            return
        }
        reply(Data("{}".utf8), nil)
    }

    private func finishRemoteCommand(
        _ id: UUID, result: WindowMoveResult,
        reply: @escaping @Sendable (Data?, String?) -> Void
    ) {
        guard let command = remoteCommand, command.id == id else { return }
        remoteCommand = nil
        do {
            reply(try JSONEncoder().encode(result), nil)
        } catch {
            reply(nil, "encoding_failed")
        }
    }

    private func cancelRemoteCommand(code: WindowMoveResultCode) {
        guard let command = remoteCommand else {
            controller.cancelRemoteOperations()
            return
        }
        if code == .cancelled {
            command.cancel()
        } else {
            command.terminate(code: code)
        }
    }

    private func respond(
        _ request: WindowMoveRequest, code: WindowMoveResultCode,
        reply: @escaping @Sendable (Data?, String?) -> Void
    ) {
        do {
            reply(
                try JSONEncoder().encode(
                    WindowMoveResult(
                        requestID: request.id, displayID: request.displayID, code: code)),
                nil)
        } catch {
            reply(nil, "encoding_failed")
        }
    }

}

@MainActor
private final class WindowAgentEndpoint: NSObject, MacTowerWindowAgentXPCProtocol {
    private weak var bridge: WindowAgentBridge?
    private let connectionID: UUID

    init(bridge: WindowAgentBridge, connectionID: UUID) {
        self.bridge = bridge
        self.connectionID = connectionID
    }

    nonisolated func moveActiveWindow(
        _ request: Data, withReply reply: @escaping @Sendable (Data?, String?) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self, let bridge = self.bridge else {
                reply(nil, "unavailable")
                return
            }
            bridge.moveActiveWindow(request, connectionID: self.connectionID, reply: reply)
        }
    }

    nonisolated func cancelRemoteWindowCommands() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.bridge?.cancelRemoteCommands(connectionID: self.connectionID)
        }
    }

    nonisolated func deliverUserNotification(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data?, String?) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self, let bridge = self.bridge else {
                reply(nil, "unavailable")
                return
            }
            await bridge.deliverUserNotification(
                request,
                connectionID: self.connectionID,
                reply: reply
            )
        }
    }

    nonisolated func removeUserNotification(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data?, String?) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self, let bridge = self.bridge else {
                reply(nil, "unavailable")
                return
            }
            await bridge.removeUserNotification(
                request,
                connectionID: self.connectionID,
                reply: reply
            )
        }
    }
}
