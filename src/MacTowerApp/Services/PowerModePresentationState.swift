import Foundation
import MacTowerCore

struct PowerModePresentationState: Equatable {
    private(set) var confirmedStatus: PowerControlStatus?
    private(set) var pendingMode: PowerMode?
    private(set) var errorMessage: String?
    private var pendingRequestID: UUID?

    var displayedMode: PowerMode? {
        pendingMode ?? confirmedStatus?.requestedMode
    }

    init(confirmedStatus: PowerControlStatus? = nil) {
        self.confirmedStatus = confirmedStatus
    }

    mutating func begin(_ mode: PowerMode) -> UUID {
        let id = UUID()
        pendingRequestID = id
        pendingMode = mode
        errorMessage = nil
        return id
    }

    @discardableResult
    mutating func confirm(_ status: PowerControlStatus, requestID: UUID) -> Bool {
        guard pendingRequestID == requestID else { return false }
        confirmedStatus = status
        pendingRequestID = nil
        pendingMode = nil
        errorMessage = nil
        return true
    }

    @discardableResult
    mutating func fail(requestID: UUID, message: String) -> Bool {
        guard pendingRequestID == requestID else { return false }
        pendingRequestID = nil
        pendingMode = nil
        errorMessage = message
        return true
    }

    mutating func observe(_ status: PowerControlStatus?) {
        guard pendingRequestID == nil else { return }
        confirmedStatus = status
    }
}
