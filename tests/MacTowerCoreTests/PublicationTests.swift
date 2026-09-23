import Foundation
import Testing

@testable import MacTowerCore

@Suite("Read-only HTTP and MQTT publication")
struct PublicationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_300)

    @Test("HTTP exposes only known GET routes to allowed IPv4 peers")
    func httpRoutesAndACL() async throws {
        let store = SnapshotStore()
        await store.recordSuccess(sampleSnapshot, attemptedAt: now)
        let router = SensorHTTPRouter(
            store: store,
            allowedNetworks: [try IPv4CIDR("192.168.50.0/24")],
            staleAfterSeconds: 900
        )

        let health = await router.handle(
            .init(method: "GET", path: "/health", peerAddress: "192.168.50.20"), now: now)
        let accounts = await router.handle(
            .init(method: "GET", path: "/v1/accounts", peerAddress: "192.168.50.20"), now: now)
        let sensors = await router.handle(
            .init(method: "GET", path: "/v1/sensors", peerAddress: "192.168.50.20"), now: now)
        let write = await router.handle(
            .init(method: "POST", path: "/v1/sensors", peerAddress: "192.168.50.20"), now: now)
        let denied = await router.handle(
            .init(method: "GET", path: "/health", peerAddress: "10.0.0.5"), now: now)
        let unknown = await router.handle(
            .init(method: "GET", path: "/v1/unknown", peerAddress: "192.168.50.20"), now: now)

        #expect(health.status == 200)
        #expect(accounts.status == 200)
        #expect(String(decoding: accounts.body, as: UTF8.self).contains("deepseek-main"))
        #expect(sensors.status == 200)
        #expect(String(decoding: sensors.body, as: UTF8.self).contains(#""freshness":"fresh""#))
        #expect(write.status == 405)
        #expect(denied.status == 403)
        #expect(unknown.status == 404)
    }

    @Test("HTTP JSON keeps an absent reset count distinct from zero")
    func absentVersusZero() async throws {
        let store = SnapshotStore()
        let withoutCredits = sampleSnapshot
        let withZeroCredits = AccountSnapshot(
            id: AccountID("codex-zero"),
            provider: .codex,
            label: "Zero",
            status: .available,
            source: .codexAppServer,
            observedAt: now,
            resetCredits: RateLimitResetCredits(availableCount: 0, credits: [])
        )
        await store.recordSuccess(withoutCredits, attemptedAt: now)
        await store.recordSuccess(withZeroCredits, attemptedAt: now)
        let router = SensorHTTPRouter(
            store: store,
            allowedNetworks: [try IPv4CIDR("127.0.0.0/8")],
            staleAfterSeconds: 900
        )

        let response = await router.handle(
            .init(method: "GET", path: "/v1/sensors", peerAddress: "127.0.0.1"),
            now: now
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let accounts = try #require(object["accounts"] as? [[String: Any]])
        let missing = try #require(accounts.first { $0["id"] as? String == "deepseek-main" })
        let zero = try #require(accounts.first { $0["id"] as? String == "codex-zero" })
        #expect(missing["resetCredits"] == nil)
        #expect((zero["resetCredits"] as? [String: Any])?["availableCount"] as? Int == 0)
    }

    @Test("MQTT planner emits retained Home Assistant discovery and state")
    func mqttDiscoveryAndState() throws {
        let planner = HomeAssistantMQTTPlanner(topicPrefix: "mac_tower")
        let publications = try planner.snapshotPublications(
            entries: [
                StoredSnapshot(snapshot: sampleSnapshot, lastAttemptAt: now, lastFailure: nil)
            ],
            now: now,
            staleAfterSeconds: 900,
            includeDiscovery: true
        )

        #expect(
            publications.contains {
                $0.topic == "mac_tower/availability"
                    && String(decoding: $0.payload, as: UTF8.self) == "online" && $0.retain
            })
        #expect(
            publications.contains {
                $0.topic == "mac_tower/accounts/deepseek-main/state" && $0.retain
            })
        let totalDiscovery = try #require(
            publications.first {
                $0.topic == "homeassistant/sensor/mac_tower_deepseek-main_balance_usd_total/config"
            }
        )
        let json = try #require(
            JSONSerialization.jsonObject(with: totalDiscovery.payload) as? [String: Any])
        #expect(json["unique_id"] as? String == "mac_tower_deepseek-main_balance_usd_total")
        #expect(json["availability_topic"] as? String == "mac_tower/availability")
        #expect(totalDiscovery.retain)
    }

    @Test(
        "Reconnect and Home Assistant birth republish discovery without changing observation time")
    func mqttRepublish() throws {
        let planner = HomeAssistantMQTTPlanner(topicPrefix: "mac_tower")
        let entries = [
            StoredSnapshot(snapshot: sampleSnapshot, lastAttemptAt: now, lastFailure: nil)
        ]
        let reconnect = try planner.reconnectPublications(
            entries: entries, now: now.addingTimeInterval(60), staleAfterSeconds: 900)
        let birth = try planner.homeAssistantBirthPublications(
            entries: entries, now: now.addingTimeInterval(60), staleAfterSeconds: 900)

        #expect(reconnect.contains { $0.topic.hasPrefix("homeassistant/") })
        #expect(birth.contains { $0.topic.hasPrefix("homeassistant/") })
        let state = try #require(reconnect.first { $0.topic.hasSuffix("/state") })
        #expect(String(decoding: state.payload, as: UTF8.self).contains("1800000000"))
    }

    @Test("Removing an account clears retained state and discovery topics")
    func mqttRemovalTombstones() throws {
        let planner = HomeAssistantMQTTPlanner(topicPrefix: "mac_tower")
        let tombstones = try planner.removalPublications(for: sampleSnapshot)

        #expect(
            tombstones.contains {
                $0.topic == "mac_tower/accounts/deepseek-main/state" && $0.payload.isEmpty
                    && $0.retain
            })
        #expect(
            tombstones.contains {
                $0.topic.hasPrefix("homeassistant/") && $0.payload.isEmpty && $0.retain
            })
    }

    @Test("Publication selection filters accounts and individual fields")
    func publicationSelection() async throws {
        let selection = try PublicationSelection(
            accountIDs: [sampleSnapshot.id],
            fields: [.balanceTotal]
        )
        let store = SnapshotStore()
        await store.recordSuccess(sampleSnapshot, attemptedAt: now)
        await store.recordSuccess(
            AccountSnapshot(
                id: AccountID("other"),
                provider: .deepSeek,
                label: "Other",
                status: .available,
                source: .deepSeekAPI,
                observedAt: now
            ),
            attemptedAt: now
        )
        let router = SensorHTTPRouter(
            store: store,
            allowedNetworks: [try IPv4CIDR("127.0.0.0/8")],
            staleAfterSeconds: 900,
            selection: selection
        )
        let response = await router.handle(
            .init(method: "GET", path: "/v1/sensors", peerAddress: "127.0.0.1"),
            now: now
        )
        let json = String(decoding: response.body, as: UTF8.self)
        #expect(json.contains("deepseek-main"))
        #expect(!json.contains(#"\"id\":\"other\""#))
        #expect(json.contains(#""total""#))
        #expect(!json.contains(#""granted""#))
        #expect(!json.contains(#""toppedUp""#))

        let planner = HomeAssistantMQTTPlanner(topicPrefix: "mac_tower")
        let entries = [
            StoredSnapshot(snapshot: sampleSnapshot, lastAttemptAt: now, lastFailure: nil)
        ]
        let publications = try planner.snapshotPublications(
            entries: entries,
            now: now,
            staleAfterSeconds: 900,
            includeDiscovery: true,
            selection: selection
        )
        #expect(publications.contains { $0.topic.contains("balance_usd_total") })
        #expect(!publications.contains { $0.topic.contains("balance_usd_granted") })
    }

    @Test("MQTT reconciliation retains tombstones until a successful advertisement commit")
    func mqttTopicReconciliation() throws {
        let planner = HomeAssistantMQTTPlanner(topicPrefix: "mac_tower")
        let previous: Set<String> = [
            "mac_tower/accounts/deleted/state",
            "homeassistant/sensor/mac_tower_deleted_quota/config",
        ]
        let current: Set<String> = ["mac_tower/accounts/current/state"]
        let tombstones = planner.staleTopicPublications(
            previouslyAdvertised: previous,
            currentlyAdvertised: current
        )
        #expect(tombstones.count == 2)
        #expect(tombstones.allSatisfy { $0.payload.isEmpty && $0.retain })
    }

    private var sampleSnapshot: AccountSnapshot {
        AccountSnapshot(
            id: AccountID("deepseek-main"),
            provider: .deepSeek,
            label: "Main",
            status: .available,
            source: .deepSeekAPI,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            balances: [
                MoneyBalance(
                    currency: "USD",
                    total: try! DecimalString("10.00"),
                    granted: try! DecimalString("1.00"),
                    toppedUp: try! DecimalString("9.00")
                )
            ]
        )
    }
}
