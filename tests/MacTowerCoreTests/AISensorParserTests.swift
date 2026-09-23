import Foundation
import Testing

@testable import MacTowerCore

@Suite("AI sensor provider parsing")
struct AISensorParserTests {
    private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Codex preserves multiple quota buckets and reset credits")
    func codexMultiBucketQuota() throws {
        let payload = Data(
            #"""
            {
              "rateLimits": {
                "limitId": "codex",
                "limitName": null,
                "primary": {"usedPercent": 25, "windowDurationMins": 15, "resetsAt": 1800000900},
                "secondary": null,
                "rateLimitReachedType": null
              },
              "rateLimitsByLimitId": {
                "codex": {
                  "limitId": "codex",
                  "limitName": "Codex",
                  "primary": {"usedPercent": 25, "windowDurationMins": 15, "resetsAt": 1800000900},
                  "secondary": {"usedPercent": 80, "windowDurationMins": 10080, "resetsAt": 1800604800},
                  "rateLimitReachedType": null,
                  "planType": "pro"
                },
                "codex_other": {
                  "limitId": "codex_other",
                  "limitName": "Other",
                  "primary": {"usedPercent": 42.5, "windowDurationMins": 60, "resetsAt": 1800003600},
                  "secondary": null,
                  "rateLimitReachedType": null
                }
              },
              "rateLimitResetCredits": {
                "availableCount": 2,
                "credits": [{
                  "id": "opaque-credit-id",
                  "resetType": "codexRateLimits",
                  "status": "available",
                  "grantedAt": 1799990000,
                  "expiresAt": 1800100000,
                  "title": "Rate-limit reset",
                  "description": "Reset an eligible window"
                }]
              }
            }
            """#.utf8
        )

        let snapshot = try CodexRateLimitsParser().parse(
            payload,
            accountID: AccountID("codex-personal"),
            label: "Personal",
            observedAt: observedAt
        )

        #expect(snapshot.provider == .codex)
        #expect(snapshot.plan == "pro")
        #expect(snapshot.quotas.count == 3)
        #expect(snapshot.quotas[0].id == "codex.primary")
        #expect(snapshot.quotas[0].usedPercent == 25)
        #expect(snapshot.quotas[0].remainingPercent == 75)
        #expect(snapshot.quotas[1].id == "codex.secondary")
        #expect(snapshot.quotas[1].windowDurationMinutes == 10_080)
        #expect(snapshot.quotas[2].usedPercent == 42.5)
        #expect(snapshot.resetCredits?.availableCount == 2)
        #expect(
            snapshot.resetCredits?.credits?.first?.expiresAt
                == Date(timeIntervalSince1970: 1_800_100_000))
    }

    @Test("Claude accepts only quota fields from statusline input")
    func claudeStatuslineFiltering() throws {
        let payload = Data(
            #"""
            {
              "session_id": "private-session",
              "transcript_path": "/Users/person/.claude/transcript.jsonl",
              "workspace": {"current_dir": "/Users/person/secret-project"},
              "rate_limits": {
                "five_hour": {"used_percentage": 12.5, "resets_at": 1800003600},
                "seven_day": {"used_percentage": 63, "resets_at": 1800604800}
              }
            }
            """#.utf8
        )

        let snapshot = try ClaudeStatuslineParser().parse(
            payload,
            accountID: AccountID("claude-work"),
            label: "Work",
            observedAt: observedAt
        )

        #expect(snapshot.provider == .claude)
        #expect(snapshot.quotas.map(\.id) == ["five_hour", "seven_day"])
        #expect(snapshot.quotas.map(\.usedPercent) == [12.5, 63])
        #expect(snapshot.quotas.map(\.windowDurationMinutes) == [300, 10_080])

        let encoded = try PublicSnapshotEncoder().encode([snapshot])
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("private-session"))
        #expect(!json.contains("transcript"))
        #expect(!json.contains("secret-project"))
    }

    @Test("DeepSeek preserves decimal strings and currencies")
    func deepSeekBalances() throws {
        let payload = Data(
            #"""
            {
              "is_available": true,
              "balance_infos": [
                {"currency": "USD", "total_balance": "10.0100", "granted_balance": "0.0100", "topped_up_balance": "10.0000"},
                {"currency": "CNY", "total_balance": "0.00", "granted_balance": "0.00", "topped_up_balance": "0.00"}
              ]
            }
            """#.utf8
        )

        let snapshot = try DeepSeekBalanceParser().parse(
            payload,
            accountID: AccountID("deepseek-main"),
            label: "Main key",
            observedAt: observedAt
        )

        #expect(snapshot.provider == .deepSeek)
        #expect(snapshot.status == .available)
        #expect(snapshot.balances[0].currency == "USD")
        #expect(snapshot.balances[0].total.value == "10.0100")
        #expect(snapshot.balances[0].granted.value == "0.0100")
        #expect(snapshot.balances[1].total.value == "0.00")
    }

    @Test("Missing metrics remain absent and stale data is explicit")
    func absentMetricsAndFreshness() throws {
        let payload = Data(#"{"is_available":false,"balance_infos":[]}"#.utf8)
        let snapshot = try DeepSeekBalanceParser().parse(
            payload,
            accountID: AccountID("deepseek-empty"),
            label: "Empty",
            observedAt: observedAt
        )

        #expect(snapshot.status == .unavailable)
        #expect(snapshot.balances.isEmpty)
        #expect(snapshot.quotas.isEmpty)
        #expect(snapshot.freshness(at: observedAt, staleAfter: 300) == .unavailable)

        let available = try DeepSeekBalanceParser().parse(
            Data(#"{"is_available":true,"balance_infos":[]}"#.utf8),
            accountID: AccountID("deepseek-available"),
            label: "Available",
            observedAt: observedAt
        )
        #expect(
            available.freshness(at: observedAt.addingTimeInterval(299), staleAfter: 300) == .fresh)
        #expect(
            available.freshness(at: observedAt.addingTimeInterval(300), staleAfter: 300) == .stale)
    }

    @Test("Malformed decimals are rejected instead of coerced to zero")
    func invalidDeepSeekDecimal() {
        let payload = Data(
            #"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"free","granted_balance":"0","topped_up_balance":"0"}]}"#
                .utf8
        )

        #expect(throws: SensorParsingError.self) {
            try DeepSeekBalanceParser().parse(
                payload,
                accountID: AccountID("deepseek-invalid"),
                label: "Invalid",
                observedAt: observedAt
            )
        }
    }

    @Test("Empty or out-of-range quota payloads are rejected")
    func invalidQuotaPayloads() {
        #expect(throws: SensorParsingError.self) {
            try CodexRateLimitsParser().parse(
                Data(#"{"rateLimitsByLimitId":{}}"#.utf8),
                accountID: AccountID("codex-empty"),
                label: "Empty",
                observedAt: observedAt
            )
        }
        #expect(throws: SensorParsingError.self) {
            try ClaudeStatuslineParser().parse(
                Data(#"{"rate_limits":{}}"#.utf8),
                accountID: AccountID("claude-empty"),
                label: "Empty",
                observedAt: observedAt
            )
        }
        #expect(throws: SensorParsingError.self) {
            try ClaudeStatuslineParser().parse(
                Data(
                    #"{"rate_limits":{"five_hour":{"used_percentage":101,"resets_at":1800003600}}}"#
                        .utf8),
                accountID: AccountID("claude-invalid"),
                label: "Invalid",
                observedAt: observedAt
            )
        }
    }
}
