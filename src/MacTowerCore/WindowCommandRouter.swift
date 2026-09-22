import Foundation

public enum WindowRoutingError: Error, Equatable {
    case agentAlreadyConnected
}

public struct WindowRoutingState: Equatable, Sendable {
    public let enabled: Bool
    public let epoch: UUID
    public let snapshot: WindowAgentSnapshot?
}

/// Routes only live commands. Neither windows nor provider data ever enter this actor.
public actor WindowCommandRouter {
    public typealias Executor =
        @Sendable (
            WindowMoveRequest, @escaping @Sendable (WindowMoveResult) -> Void
        ) -> Void

    private var enabled: Bool
    private var brokerConnected = false
    private var epoch = UUID()
    private var agentID: UUID?
    private var snapshot: WindowAgentSnapshot?
    private var lastHeartbeat: TimeInterval = 0
    private var execute: Executor?
    private var cancel: (@Sendable () -> Void)?
    private var inFlight: UUID?
    private let commandTimeout: Duration
    private let leaseSeconds: TimeInterval = 5

    public init(enabled: Bool = false, commandTimeout: Duration = .seconds(22)) {
        self.enabled = enabled
        self.commandTimeout = commandTimeout
    }

    public func updateAgent(
        id: UUID,
        snapshot replacement: WindowAgentSnapshot,
        execute: @escaping Executor,
        cancel: @escaping @Sendable () -> Void,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) throws {
        try replacement.validate()
        expireLease(now: now)
        guard agentID == nil || agentID == id else {
            throw WindowRoutingError.agentAlreadyConnected
        }
        if agentID != id || snapshot?.generation != replacement.generation
            || !WindowTopology.matches(snapshot?.displays ?? [], replacement.displays)
            || snapshot?.availability.isEligible != replacement.availability.isEligible
        {
            rotateEpoch()
        }
        agentID = id
        snapshot = replacement
        lastHeartbeat = now
        self.execute = execute
        self.cancel = cancel
    }

    public func disconnectAgent(id: UUID) {
        guard agentID == id else { return }
        clearAgent()
    }

    public func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        rotateEpoch()
    }

    public func setBrokerConnected(_ value: Bool) {
        guard brokerConnected != value else { return }
        brokerConnected = value
        rotateEpoch()
    }

    public func state(now: TimeInterval = ProcessInfo.processInfo.systemUptime)
        -> WindowRoutingState
    {
        expireLease(now: now)
        return WindowRoutingState(enabled: enabled, epoch: epoch, snapshot: snapshot)
    }

    public func move(
        displayID: String,
        epoch requestedEpoch: UUID,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) async -> WindowMoveResult? {
        expireLease(now: now)
        guard enabled, brokerConnected, requestedEpoch == epoch,
            let snapshot, snapshot.availability.isEligible,
            snapshot.displays.contains(where: { $0.id == displayID }), let execute
        else { return nil }
        let request = WindowMoveRequest(
            displayID: displayID, generation: snapshot.generation, epoch: epoch)
        guard inFlight == nil else {
            return .init(requestID: request.id, displayID: displayID, code: .busy)
        }
        inFlight = request.id
        let cancel = self.cancel
        let timeout = commandTimeout
        let result = await withCheckedContinuation { continuation in
            let gate = WindowResultGate(continuation)
            let timer = Task {
                do { try await Task.sleep(for: timeout, clock: .continuous) } catch { return }
                if gate.finish(.init(requestID: request.id, displayID: displayID, code: .timeout)) {
                    cancel?()
                }
            }
            execute(request) { response in
                let checked =
                    response.requestID == request.id && response.displayID == displayID
                    ? response
                    : .init(requestID: request.id, displayID: displayID, code: .invalidCommand)
                if gate.finish(checked) { timer.cancel() }
            }
        }
        inFlight = nil
        return result
    }

    private func expireLease(now: TimeInterval) {
        if agentID != nil && (now < lastHeartbeat || now - lastHeartbeat > leaseSeconds) {
            clearAgent()
        }
    }

    private func clearAgent() {
        rotateEpoch()
        agentID = nil
        if let previous = snapshot {
            snapshot = WindowAgentSnapshot(
                generation: UUID(), displays: previous.displays, availability: .unavailable
            )
        }
        execute = nil
        cancel = nil
    }

    private func rotateEpoch() {
        epoch = UUID()
        cancel?()
    }
}

private final class WindowResultGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WindowMoveResult, Never>?

    init(_ continuation: CheckedContinuation<WindowMoveResult, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func finish(_ result: WindowMoveResult) -> Bool {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        current?.resume(returning: result)
        return current != nil
    }
}
