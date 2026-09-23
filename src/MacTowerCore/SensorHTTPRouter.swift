import Foundation

public struct SensorHTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let peerAddress: String

    public init(method: String, path: String, peerAddress: String) {
        self.method = method
        self.path = path
        self.peerAddress = peerAddress
    }
}

public struct SensorHTTPResponse: Equatable, Sendable {
    public let status: Int
    public let contentType: String
    public let body: Data

    public init(status: Int, contentType: String = "application/json", body: Data) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }
}

public struct PublicSensorAccount: Codable, Equatable, Sendable {
    public let id: AccountID
    public let provider: AIProvider
    public let label: String
    public let plan: String?
    public let status: AccountStatus
    public let source: SnapshotSource
    public let observedAt: Date
    public let freshness: SensorFreshness
    public let lastAttemptAt: Date
    public let lastFailure: CollectionFailure?
    public let quotas: [PublishedQuotaWindow]
    public let resetCredits: RateLimitResetCredits?
    public let balances: [PublishedMoneyBalance]

    public init(
        entry: StoredSnapshot,
        now: Date,
        staleAfterSeconds: Int,
        selection: PublicationSelection = .all
    ) {
        let snapshot = entry.snapshot
        id = snapshot.id
        provider = snapshot.provider
        label = snapshot.label
        plan = snapshot.plan
        status = snapshot.status
        source = snapshot.source
        observedAt = snapshot.observedAt
        freshness = snapshot.freshness(at: now, staleAfter: TimeInterval(staleAfterSeconds))
        lastAttemptAt = entry.lastAttemptAt
        lastFailure = entry.lastFailure
        let publishesQuota =
            selection.includes(.quotaUsed)
            || selection.includes(.quotaRemaining)
            || selection.includes(.quotaWindowDuration)
            || selection.includes(.quotaResetsAt)
        quotas =
            publishesQuota
            ? snapshot.quotas.map { PublishedQuotaWindow($0, selection: selection) } : []
        resetCredits = selection.includes(.resetCredits) ? snapshot.resetCredits : nil
        let publishesBalance =
            selection.includes(.balanceTotal)
            || selection.includes(.balanceGranted) || selection.includes(.balanceToppedUp)
        balances =
            publishesBalance
            ? snapshot.balances.map { PublishedMoneyBalance($0, selection: selection) } : []
    }
}

public struct PublishedQuotaWindow: Codable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let usedPercent: Double?
    public let remainingPercent: Double?
    public let windowDurationMinutes: Int?
    public let resetsAt: Date?

    init(_ quota: QuotaWindow, selection: PublicationSelection) {
        id = quota.id
        name = quota.name
        usedPercent = selection.includes(.quotaUsed) ? quota.usedPercent : nil
        remainingPercent = selection.includes(.quotaRemaining) ? quota.remainingPercent : nil
        windowDurationMinutes =
            selection.includes(.quotaWindowDuration)
            ? quota.windowDurationMinutes : nil
        resetsAt = selection.includes(.quotaResetsAt) ? quota.resetsAt : nil
    }
}

public struct PublishedMoneyBalance: Codable, Equatable, Sendable {
    public let currency: String
    public let total: DecimalString?
    public let granted: DecimalString?
    public let toppedUp: DecimalString?

    init(_ balance: MoneyBalance, selection: PublicationSelection) {
        currency = balance.currency
        total = selection.includes(.balanceTotal) ? balance.total : nil
        granted = selection.includes(.balanceGranted) ? balance.granted : nil
        toppedUp = selection.includes(.balanceToppedUp) ? balance.toppedUp : nil
    }
}

public struct SensorHTTPRouter: Sendable {
    private let store: SnapshotStore
    private let allowedNetworks: [IPv4CIDR]
    private let staleAfterSeconds: Int
    private let selection: PublicationSelection

    public init(
        store: SnapshotStore,
        allowedNetworks: [IPv4CIDR],
        staleAfterSeconds: Int,
        selection: PublicationSelection = .all
    ) {
        self.store = store
        self.allowedNetworks = allowedNetworks
        self.staleAfterSeconds = staleAfterSeconds
        self.selection = selection
    }

    public func handle(_ request: SensorHTTPRequest, now: Date = Date()) async -> SensorHTTPResponse
    {
        guard allowedNetworks.contains(where: { $0.contains(request.peerAddress) }) else {
            return errorResponse(status: 403, code: "forbidden")
        }
        guard request.method == "GET" else {
            return errorResponse(status: 405, code: "method_not_allowed")
        }

        let path =
            request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        do {
            switch path {
            case "/health":
                return try json(status: 200, value: HealthResponse(status: "ok"))
            case "/v1/accounts":
                let entries = await store.all().filter {
                    selection.includes(accountID: $0.snapshot.id)
                }
                let accounts = entries.map {
                    AccountSummary(
                        id: $0.snapshot.id,
                        provider: $0.snapshot.provider,
                        label: $0.snapshot.label,
                        status: $0.snapshot.status,
                        freshness: $0.snapshot.freshness(
                            at: now, staleAfter: TimeInterval(staleAfterSeconds))
                    )
                }
                return try json(status: 200, value: AccountsResponse(accounts: accounts))
            case "/v1/sensors":
                let accounts = await store.all().filter {
                    selection.includes(accountID: $0.snapshot.id)
                }.map {
                    PublicSensorAccount(
                        entry: $0,
                        now: now,
                        staleAfterSeconds: staleAfterSeconds,
                        selection: selection
                    )
                }
                return try json(
                    status: 200,
                    value: SensorsResponse(generatedAt: now, accounts: accounts)
                )
            default:
                return errorResponse(status: 404, code: "not_found")
            }
        } catch {
            return errorResponse(status: 500, code: "encoding_failed")
        }
    }

    private func json<Value: Encodable>(status: Int, value: Value) throws -> SensorHTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return SensorHTTPResponse(status: status, body: try encoder.encode(value))
    }

    private func errorResponse(status: Int, code: String) -> SensorHTTPResponse {
        SensorHTTPResponse(status: status, body: Data("{\"error\":\"\(code)\"}".utf8))
    }
}

private struct HealthResponse: Codable {
    let status: String
}

private struct AccountSummary: Codable {
    let id: AccountID
    let provider: AIProvider
    let label: String
    let status: AccountStatus
    let freshness: SensorFreshness
}

private struct AccountsResponse: Codable {
    let accounts: [AccountSummary]
}

private struct SensorsResponse: Codable {
    let generatedAt: Date
    let accounts: [PublicSensorAccount]
}
