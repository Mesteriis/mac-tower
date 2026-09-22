import MacTowerCore

extension PowerMode {
    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .keepMacAwake: "Keep Mac awake"
        case .keepMacAndDisplaysAwake: "Keep Mac and displays awake"
        }
    }
}

extension PowerControlIssue {
    var explanation: String {
        switch self {
        case .invalidSettings:
            "Saved sleep settings are invalid. MacTower is not preventing sleep."
        case .persistenceFailed:
            "The choice was not saved and the previous mode may return after restart."
        case .assertionCreateFailed:
            "macOS did not apply the requested sleep mode."
        case .assertionReleaseFailed:
            "macOS did not release every MacTower sleep restriction. Try again."
        }
    }
}
