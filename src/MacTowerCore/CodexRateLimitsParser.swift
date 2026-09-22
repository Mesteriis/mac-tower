import Foundation

public struct CodexRateLimitsParser: Sendable {
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

        let buckets: [(String, Bucket)]
        if let mapped = response.rateLimitsByLimitId {
            buckets = mapped.sorted { $0.key < $1.key }
        } else if let legacy = response.rateLimits {
            buckets = [(legacy.limitId, legacy)]
        } else {
            throw SensorParsingError.invalidPayload
        }

        var quotas: [QuotaWindow] = []
        for (key, bucket) in buckets {
            if let primary = bucket.primary {
                quotas.append(try primary.quota(id: "\(key).primary", name: bucket.limitName))
            }
            if let secondary = bucket.secondary {
                quotas.append(try secondary.quota(id: "\(key).secondary", name: bucket.limitName))
            }
        }
        guard !quotas.isEmpty else { throw SensorParsingError.invalidPayload }

        let credits = response.rateLimitResetCredits.map { value in
            RateLimitResetCredits(
                availableCount: value.availableCount,
                credits: value.credits?.map { credit in
                    RateLimitResetCredit(
                        id: credit.id,
                        resetType: credit.resetType,
                        status: credit.status,
                        grantedAt: Date(timeIntervalSince1970: credit.grantedAt),
                        expiresAt: credit.expiresAt.map(Date.init(timeIntervalSince1970:)),
                        title: credit.title,
                        description: credit.description
                    )
                }
            )
        }

        return AccountSnapshot(
            id: accountID,
            provider: .codex,
            label: label,
            plan: buckets.compactMap(\.1.planType).first,
            status: .available,
            source: .codexAppServer,
            observedAt: observedAt,
            quotas: quotas,
            resetCredits: credits
        )
    }
}

extension CodexRateLimitsParser {
    fileprivate struct Response: Decodable {
        let rateLimits: Bucket?
        let rateLimitsByLimitId: [String: Bucket]?
        let rateLimitResetCredits: Credits?
    }

    fileprivate struct Bucket: Decodable {
        let limitId: String
        let limitName: String?
        let primary: Window?
        let secondary: Window?
        let planType: String?
    }

    fileprivate struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int
        let resetsAt: TimeInterval

        func quota(id: String, name: String?) throws -> QuotaWindow {
            guard usedPercent.isFinite, (0...100).contains(usedPercent),
                windowDurationMins > 0, windowDurationMins <= 525_600,
                resetsAt.isFinite, resetsAt > 0
            else {
                throw SensorParsingError.invalidPayload
            }
            return QuotaWindow(
                id: id,
                name: name,
                usedPercent: usedPercent,
                windowDurationMinutes: windowDurationMins,
                resetsAt: Date(timeIntervalSince1970: resetsAt)
            )
        }
    }

    fileprivate struct Credits: Decodable {
        let availableCount: Int
        let credits: [Credit]?
    }

    fileprivate struct Credit: Decodable {
        let id: String
        let resetType: String
        let status: String
        let grantedAt: TimeInterval
        let expiresAt: TimeInterval?
        let title: String?
        let description: String?
    }
}
