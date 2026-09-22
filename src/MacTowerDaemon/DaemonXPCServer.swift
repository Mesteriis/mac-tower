import Foundation
import MacTowerCore

final class DaemonXPCServer: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private let service: ManagementXPCService
    private let ownerUID: uid_t

    init(controller: ManagementController, trustManifestURL: URL) throws {
        let data = try Data(contentsOf: trustManifestURL)
        let manifest = try JSONDecoder().decode(TrustManifest.self, from: data)
        _ = try manifest.daemonRequirement()
        ownerUID = manifest.ownerUID
        service = ManagementXPCService(controller: controller)
        listener = NSXPCListener(machServiceName: "dev.mactower.daemon")
        super.init()
        listener.delegate = self
        listener.setConnectionCodeSigningRequirement(try manifest.appRequirement())
    }

    func start() {
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
        -> Bool
    {
        guard connection.effectiveUserIdentifier == ownerUID else { return false }
        connection.exportedInterface = NSXPCInterface(with: MacTowerDaemonXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private final class ManagementXPCService: NSObject, MacTowerDaemonXPCProtocol, @unchecked Sendable {
    private let controller: ManagementController

    init(controller: ManagementController) {
        self.controller = controller
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
        }
    }

    private func requiredPayload(_ envelope: ManagementEnvelope) throws -> Data {
        guard let payload = envelope.payload else { throw ManagementControllerError.invalidRequest }
        return payload
    }
}
