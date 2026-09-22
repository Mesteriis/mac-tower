import Foundation

public struct DeepSeekBalanceParser: Sendable {
    public init() {}

    public func parse(
        _ data: Data,
        accountID: AccountID,
        label: String,
        observedAt: Date
    ) throws -> AccountSnapshot {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw SensorParsingError.invalidPayload
        }

        let balances = try response.balanceInfos.map { balance in
            MoneyBalance(
                currency: balance.currency,
                total: try DecimalString(balance.totalBalance),
                granted: try DecimalString(balance.grantedBalance),
                toppedUp: try DecimalString(balance.toppedUpBalance)
            )
        }

        return AccountSnapshot(
            id: accountID,
            provider: .deepSeek,
            label: label,
            status: response.isAvailable ? .available : .unavailable,
            source: .deepSeekAPI,
            observedAt: observedAt,
            balances: balances
        )
    }
}

extension DeepSeekBalanceParser {
    fileprivate struct Response: Decodable {
        let isAvailable: Bool
        let balanceInfos: [Balance]

        enum CodingKeys: String, CodingKey {
            case isAvailable = "is_available"
            case balanceInfos = "balance_infos"
        }
    }

    fileprivate struct Balance: Decodable {
        let currency: String
        let totalBalance: String
        let grantedBalance: String
        let toppedUpBalance: String

        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
            case grantedBalance = "granted_balance"
            case toppedUpBalance = "topped_up_balance"
        }
    }
}
