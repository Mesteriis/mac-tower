import Foundation
import MacTowerCore

/// Connection-scoped consent and replay protection, independent of XPC transport.
struct WindowBridgeSession {
    private(set) var connectionID: UUID?
    private(set) var isConnected = false
    private(set) var remoteEnabled = false
    private(set) var commandEpoch: UUID?
    private(set) var revision = 0
    private var recentRequests: [UUID] = []

    mutating func connect(_ id: UUID) {
        connectionID = id
        isConnected = false
        remoteEnabled = false
        commandEpoch = nil
        revision += 1
        recentRequests.removeAll()
    }

    mutating func disconnect() {
        connectionID = nil
        isConnected = false
        remoteEnabled = false
        commandEpoch = nil
        revision += 1
        recentRequests.removeAll()
    }

    mutating func beginPreferenceChange(enabled: Bool) {
        revision += 1
        if !enabled {
            remoteEnabled = false
            commandEpoch = nil
        }
    }

    mutating func cancelRemoteCommands() {
        revision += 1
        remoteEnabled = false
        commandEpoch = nil
    }

    @discardableResult
    mutating func acknowledge(_ status: WindowBridgeStatus, connectionID id: UUID, revision: Int)
        -> Bool
    {
        guard connectionID == id else { return false }
        isConnected = true
        guard self.revision == revision else { return false }
        remoteEnabled = status.enabled
        commandEpoch = status.enabled ? status.epoch : nil
        return true
    }

    func permits(_ request: WindowMoveRequest, connectionID id: UUID) -> Bool {
        connectionID == id && isConnected && remoteEnabled && commandEpoch == request.epoch
    }

    mutating func admit(
        _ request: WindowMoveRequest, connectionID id: UUID, isBusy: Bool
    ) -> WindowMoveResultCode? {
        guard permits(request, connectionID: id) else { return .unavailable }
        guard UUID(uuidString: request.displayID) != nil,
            !recentRequests.contains(request.id)
        else { return .invalidCommand }
        guard !isBusy else { return .busy }
        recentRequests.append(request.id)
        if recentRequests.count > 256 { recentRequests.removeFirst() }
        return nil
    }
}
