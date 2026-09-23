import Foundation

public struct ClaudeStatuslineParser: Sendable {
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

        var quotas: [QuotaWindow] = []
        if let fiveHour = response.rateLimits.fiveHour {
            quotas.append(try fiveHour.quota(id: "five_hour", minutes: 300))
        }
        if let sevenDay = response.rateLimits.sevenDay {
            quotas.append(try sevenDay.quota(id: "seven_day", minutes: 10_080))
        }
        guard !quotas.isEmpty else { throw SensorParsingError.invalidPayload }

        return AccountSnapshot(
            id: accountID,
            provider: .claude,
            label: label,
            status: .available,
            source: .claudeStatusline,
            observedAt: observedAt,
            quotas: quotas
        )
    }
}

extension ClaudeStatuslineParser {
    fileprivate struct Response: Decodable {
        let rateLimits: RateLimits

        enum CodingKeys: String, CodingKey {
            case rateLimits = "rate_limits"
        }
    }

    fileprivate struct RateLimits: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    fileprivate struct Window: Decodable {
        let usedPercentage: Double
        let resetsAt: TimeInterval

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }

        func quota(id: String, minutes: Int) throws -> QuotaWindow {
            guard usedPercentage.isFinite, (0...100).contains(usedPercentage),
                resetsAt.isFinite, resetsAt > 0
            else {
                throw SensorParsingError.invalidPayload
            }
            return QuotaWindow(
                id: id,
                name: nil,
                usedPercent: usedPercentage,
                windowDurationMinutes: minutes,
                resetsAt: Date(timeIntervalSince1970: resetsAt)
            )
        }
    }
}
