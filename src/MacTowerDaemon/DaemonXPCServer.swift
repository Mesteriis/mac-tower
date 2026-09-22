import Foundation
import MacTowerCore

final class DaemonXPCServer: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private let controller: ManagementController
    private let windowControl: WindowControlService
    private let ownerUID: uid_t
    private let appRequirement: String

    init(
        controller: ManagementController, windowControl: WindowControlService, trustManifestURL: URL
    ) throws {
        let data = try Data(contentsOf: trustManifestURL)
        let manifest = try JSONDecoder().decode(TrustManifest.self, from: data)
        _ = try manifest.daemonRequirement()
        ownerUID = manifest.ownerUID
        self.controller = controller
        self.windowControl = windowControl
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
            controller: controller, windowControl: windowControl, peer: peer)
        connection.exportedInterface = NSXPCInterface(with: MacTowerDaemonXPCProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: MacTowerWindowAgentXPCProtocol.self)
        connection.setCodeSigningRequirement(appRequirement)
        connection.exportedObject = service
        let router = windowControl.router
        let lost: @Sendable () -> Void = {
            peer.invalidate()
            Task { await router.disconnectAgent(id: peer.id) }
        }
        connection.invalidationHandler = lost
        connection.interruptionHandler = lost
        connection.resume()
        return true
    }
}

private final class ManagementXPCService: NSObject, MacTowerDaemonXPCProtocol, @unchecked Sendable {
    private let controller: ManagementController
    private let windowControl: WindowControlService
    private let peer: WindowAgentPeer

    init(
        controller: ManagementController, windowControl: WindowControlService, peer: WindowAgentPeer
    ) {
        self.controller = controller
        self.windowControl = windowControl
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
                    throw ManagementControllerError.invalidRequest
                }
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
        guard data.count <= 1_048_576 else { throw ManagementControllerError.invalidRequest }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let envelope = try decoder.decode(ManagementEnvelope.self, from: data)
        switch envelope.operation {
        case .status:
            return try encoder.encode(await controller.status())
        case .replaceConfiguration:
            let payload = try requiredPayload(envelope)
            let request = try decoder.decode(ReplaceConfigurationRequest.self, from: payload)
            try await controller.replaceConfiguration(request)
            return Data("{}".utf8)
        case .addDeepSeekAccount:
            try await controller.addDeepSeek(
                try decoder.decode(
                    AddDeepSeekAccountRequest.self, from: requiredPayload(envelope)))
            return Data("{}".utf8)
        case .startCodexOAuth:
            let response = try await controller.startCodexOAuth(
                try decoder.decode(
                    StartCodexOAuthRequest.self, from: requiredPayload(envelope)))
            return try encoder.encode(response)
        case .cancelCodexOAuth:
            await controller.cancelCodexOAuth(
                try decoder.decode(
                    CancelCodexOAuthRequest.self, from: requiredPayload(envelope)))
            return Data("{}".utf8)
        case .linkClaudeProfile:
            try await controller.linkClaude(
                try decoder.decode(
                    LinkClaudeProfileRequest.self, from: requiredPayload(envelope)))
            return Data("{}".utf8)
        case .removeAccount:
            try await controller.removeAccount(
                try decoder.decode(
                    RemoveAccountRequest.self, from: requiredPayload(envelope)))
            return Data("{}".utf8)
        case .setPowerMode:
            // The daemon implementation is added with the power assertion owner.
            throw ManagementControllerError.invalidRequest
        }
    }

    private func requiredPayload(_ envelope: ManagementEnvelope) throws -> Data {
        guard let payload = envelope.payload else { throw ManagementControllerError.invalidRequest }
        return payload
    }
}

private final class WindowAgentPeer: @unchecked Sendable {
    let id = UUID()
    private weak var connection: NSXPCConnection?
    private let lock = NSLock()
    private var active = true

    init(connection: NSXPCConnection) { self.connection = connection }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func invalidate() {
        lock.lock()
        active = false
        lock.unlock()
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
}
