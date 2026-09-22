# Universal Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a daemon-owned universal notification engine with MQTT ingress, per-source routing, macOS Notification Center delivery, and hybrid Home Assistant/NSPanel Pro delivery.

**Architecture:** `MacTowerCore` owns the finite wire model, policy evaluation, durable state, and transition engine. The root daemon owns ingestion, retries, MQTT publishing, AI transitions, panel pairing, wake/sound, and the authenticated management surface; the user app owns only Notification Center presentation and UI. Home Assistant receives a dedicated MQTT panel event through a shipped blueprint, while the official NSPanel local API is used only for pairing, screen wake, and a finite supported sound.

**Tech Stack:** Swift 6, macOS 14+, SwiftPM, Swift Testing, SwiftUI, UserNotifications, Foundation XPC, Foundation URLSession, SwiftNIO/NIOHTTP1, MQTTNIO 2.13.0, Docker Mosquitto 2.0, Home Assistant automation blueprint YAML.

**Spec:** `docs/superpowers/specs/2026-09-22-notifications-design.md`

## Global Constraints

- Keep production code under `src`, tests under `tests`, commands in the existing `Makefile`, and macOS minimum at 14.
- HTTP remains read-only. Do not add an HTTP notification create, acknowledge, delete, pairing, or test route.
- The root LaunchDaemon is the sole notification state owner; the GUI only presents macOS notifications and sends finite acknowledgements over the existing UID/cdhash-pinned XPC connection.
- MQTT ingress and acknowledgement are separate opt-ins and default to disabled. Reject every retained ingress or acknowledgement message.
- Input topic is `<prefix>/notifications/inbox/<source_id>`; output topics are under `<prefix>/notifications/events`, `/panel`, `/active/<event_id>`, `/availability`, and `/ack`.
- Enforce 16 KiB payload, 64-character source ID, 160-character title, 2,000-character message, UUID event ID, RFC 3339 dates, expiry, future-skew, per-source rate, and global rate limits.
- An input payload cannot select channels, wake/sound behavior, quiet-hour bypass, action identifiers, templates, HTML, URLs, or commands.
- There is no hard-coded severity routing. A valid new source immediately inherits the explicit global rule; a source override replaces that rule.
- `critical` remains active until acknowledgement or expiry. `info` and `warning` are history-only after routing.
- History is capped at 5,000 records and 30 days. Text is private daemon data and never enters ordinary logs, sensor HTTP responses, Home Assistant Discovery, or availability payloads.
- NSPanel text is handed to Home Assistant through MQTT. MacTower stores no Home Assistant credential and never invents a `notify.mobile_app_*` action name.
- NSPanel direct access uses only the official local HTTP access-token, wake-up, and speaker endpoints; pin a validated private IPv4 per request, reject redirects, and keep the token in a separate root-only file.
- Mark a sound attempt durable before the HTTP call. An ambiguous sound result is not retried automatically.
- Existing AI sensors, HTTP/MQTT sensor publication, window control, and sleep control must continue when notification state or a delivery channel fails.
- Do not add a battery producer in this plan; the repository does not yet contain a battery sensor.
- No new package dependency is required.

## Review Focus

- A retained, oversized, expired, future-dated, malformed, or feedback-loop MQTT message must never create history or delivery work; Tasks 1, 5, and 7 pin each boundary.
- A crash between durable intent and handoff may duplicate MQTT but must not replay old ordinary Mac notifications or sound twice; Tasks 4, 6, and 7 pin per-channel recovery semantics.
- Quiet intervals crossing midnight, DST changes, logout/login, and daemon restart must preserve active critical state without releasing a notification storm; Tasks 2, 4, and 8 pin these transitions.
- A public/rebound NSPanel address, redirect, invalid token, oversized response, or ambiguous timeout must fail closed without logging the bearer token; Task 6 pins the client boundary.
- A forged Home Assistant action or untrusted XPC connection must not acknowledge arbitrary state; Tasks 8 and 9 require a UUID active critical plus the existing broker ACL and XPC identity checks.

## File Structure

New focused files:

- `src/MacTowerCore/NotificationModel.swift`: validated wire/domain values and public status/history DTOs.
- `src/MacTowerCore/NotificationConfiguration.swift`: global/source rules, quiet hours, AI thresholds, and finite NSPanel sound names.
- `src/MacTowerCore/NotificationPolicy.swift`: pure route and quiet-hour evaluation.
- `src/MacTowerCore/NotificationStore.swift`: versioned root-only state envelope and injected store protocol.
- `src/MacTowerCore/NotificationEngine.swift`: serialized ingestion, deduplication, retention, acknowledgement, recovery, and delivery effects.
- `src/MacTowerCore/NotificationMQTTPlanner.swift`: topic parsing and MQTT publication payloads.
- `src/MacTowerCore/AINotificationDetector.swift`: pure snapshot transition detection.
- `src/MacTowerTransport/NSPanelClient.swift`: official local HTTP pairing/wake/sound client.
- `src/MacTowerDaemon/NotificationService.swift`: daemon orchestration and channel handoff.
- `src/MacTowerApp/Services/MacNotificationController.swift`: UserNotifications authorization, presentation, replacement, removal, and acknowledgement callback.
- `src/MacTowerApp/Views/NotificationsSettingsView.swift`: settings and channel tests.
- `src/MacTowerApp/Views/NotificationHistoryView.swift`: bounded history and active critical UI.
- `homeassistant/blueprints/automation/mactower/notifications.yaml`: panel text and acknowledgement bridge.

Existing integration files remain responsible for their current concerns: `HomeAssistantMQTTPublisher` transports bytes, `DaemonNetworkRuntime` owns connection lifecycle, `DaemonXPCServer` owns trust enforcement, `DaemonClient` owns management RPC, and existing app views only compose the new focused views.

---

### Task 1: Validated notification wire and domain model

**Files:**
- Create: `src/MacTowerCore/NotificationModel.swift`
- Create: `tests/MacTowerCoreTests/NotificationModelTests.swift`

**Interfaces:**
- Consumes: Foundation `UUID`, `Date`, Codable conventions, and the existing `MQTTPublication` type only in later tasks.
- Produces: `NotificationSourceID`, `NotificationSeverity`, `NotificationIngress`, `NotificationEvent`, `NotificationChannel`, `NotificationDeliveryState`, `NotificationChannelDelivery`, `NotificationDeliveryPlan`, `NSPanelSoundName`, `NSPanelSound`, `NotificationAcknowledgementActor`, `NotificationRecord`, `NotificationAcknowledgement`, `MacNotificationDelivery`, `NotificationHistoryPage`, `NotificationEngineSummary`, `NotificationSummary`, and `NotificationWireCodec`.

- [ ] **Step 1: Write the failing model and wire-codec tests**

Pin successful RFC 3339 decoding, both standard and fractional timestamps, snake-case keys, unknown-field tolerance, and every invalid boundary:

```swift
import Foundation
import Testing
@testable import MacTowerCore

@Suite("Notification model")
struct NotificationModelTests {
    @Test func validIngressBecomesFiniteEvent() throws {
        let data = Data(#"{"schema_version":1,"event_id":"550e8400-e29b-41d4-a716-446655440000","severity":"warning","title":"UPS","message":"On battery","created_at":"2026-09-22T18:30:00.123Z","expires_at":"2026-09-22T19:30:00Z","dedup_key":"ups-on-battery","ignored":true}"#.utf8)
        let input = try NotificationWireCodec().decodeIngress(
            data, sourceID: "ups.main", now: Date(timeIntervalSince1970: 1_790_102_100))
        #expect(input.sourceID.rawValue == "ups.main")
        #expect(input.severity == .warning)
        #expect(input.title == "UPS")
        #expect(input.dedupKey == "ups-on-battery")
    }

    @Test(arguments: ["bad/source", "", String(repeating: "a", count: 65)])
    func invalidSourceIsRejected(_ source: String) {
        #expect(throws: NotificationValidationError.self) {
            try NotificationSourceID(validating: source)
        }
    }

    @Test func sizeExpiryAndFutureSkewAreRejected() {
        let codec = NotificationWireCodec()
        #expect(throws: NotificationValidationError.payloadTooLarge) {
            try codec.decodeIngress(
                Data(repeating: 65, count: NotificationWireCodec.maximumPayloadBytes + 1),
                sourceID: "source", now: .now)
        }
        let expired = Data(#"{"schema_version":1,"event_id":"550e8400-e29b-41d4-a716-446655440000","severity":"info","title":"x","message":"x","created_at":"2026-09-22T18:00:00Z","expires_at":"2026-09-22T18:01:00Z"}"#.utf8)
        #expect(throws: NotificationValidationError.expired) {
            try codec.decodeIngress(
                expired, sourceID: "source",
                now: Date(timeIntervalSince1970: 1_790_102_100))
        }
        let future = Data(#"{"schema_version":1,"event_id":"550e8400-e29b-41d4-a716-446655440000","severity":"info","title":"x","message":"x","created_at":"2026-09-22T19:00:01Z"}"#.utf8)
        #expect(throws: NotificationValidationError.futureEvent) {
            try codec.decodeIngress(
                future, sourceID: "source",
                now: Date(timeIntervalSince1970: 1_790_102_100))
        }
        for invalid in [
            #"{"schema_version":1,"event_id":"550e8400-e29b-41d4-a716-446655440000","severity":"urgent","title":"x","message":"x","created_at":"2026-09-22T18:00:00Z"}"#,
            #"{"schema_version":1,"event_id":"550e8400-e29b-41d4-a716-446655440000","severity":"info","title":"","message":"x","created_at":"2026-09-22T18:00:00Z"}"#,
            #"{"schema_version":1,"event_id":"550e8400-e29b-41d4-a716-446655440000","severity":"info","title":"x","message":"","created_at":"2026-09-22T18:00:00Z"}"#,
        ] {
            #expect(throws: Error.self) {
                try codec.decodeIngress(
                    Data(invalid.utf8), sourceID: "source",
                    now: Date(timeIntervalSince1970: 1_790_102_100))
            }
        }
    }
}
```

- [ ] **Step 2: Run the model tests and verify RED**

Run: `./src/scripts/test.sh --filter NotificationModelTests`

Expected: compile failure because the notification model does not exist.

- [ ] **Step 3: Implement exact finite types and validation**

Use these public shapes and constants:

```swift
public struct NotificationSourceID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(validating value: String) throws
}

public enum NotificationSeverity: String, Codable, CaseIterable, Sendable {
    case info, warning, critical
}

public enum NotificationChannel: String, Codable, CaseIterable, Hashable, Sendable {
    case mqtt, mac, panel
}

public enum NSPanelSoundName: String, Codable, CaseIterable, Sendable {
    case alert1, alert2, alert3, alert4, alert5
    case doorbell1, doorbell2, doorbell3, doorbell4, doorbell5
    case alarm1, alarm2, alarm3, alarm4, alarm5
}

public struct NSPanelSound: Codable, Equatable, Sendable {
    public let name: NSPanelSoundName
    public let volume: Int
    public let countdownSeconds: Int
}

public struct NotificationIngress: Equatable, Sendable {
    public let schemaVersion: Int
    public let eventID: UUID
    public let sourceID: NotificationSourceID
    public let severity: NotificationSeverity
    public let title: String
    public let message: String
    public let createdAt: Date
    public let expiresAt: Date?
    public let dedupKey: String?
}

public struct MacNotificationDelivery: Codable, Equatable, Sendable {
    public let eventID: UUID
    public let severity: NotificationSeverity
    public let title: String
    public let message: String
}

public struct NotificationEvent: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let eventID: UUID
    public let sourceID: NotificationSourceID
    public let severity: NotificationSeverity
    public let title: String
    public let message: String
    public let createdAt: Date
    public let expiresAt: Date?
    public let dedupKey: String?
}

public enum NotificationAcknowledgementActor: String, Codable, Sendable {
    case mac, homeAssistant = "home_assistant"
}

public struct NotificationAcknowledgement: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let eventID: UUID
}

public struct NotificationChannelDelivery: Codable, Equatable, Sendable {
    public var state: NotificationDeliveryState
    public var lastAttemptAt: Date?
}

public struct NotificationDeliveryPlan: Codable, Equatable, Sendable {
    public let channels: Set<NotificationChannel>
    public let wakePanel: Bool
    public let panelSound: NSPanelSound?
}

public struct NotificationRecord: Codable, Equatable, Sendable {
    public var event: NotificationEvent
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var occurrenceCount: Int
    public var isActive: Bool
    public var acknowledgedAt: Date?
    public var acknowledgedBy: NotificationAcknowledgementActor?
    public var deliveryPlan: NotificationDeliveryPlan
    public var deliveries: [NotificationChannel: NotificationChannelDelivery]
    public var panelSoundAttemptedAt: Date?
}

public struct NotificationWireCodec: Sendable {
    public static let maximumPayloadBytes = 16_384
    public static let maximumFutureSkew: TimeInterval = 300
    public func decodeIngress(_ data: Data, sourceID: String, now: Date) throws -> NotificationIngress
    public func decodeAcknowledgement(_ data: Data) throws -> NotificationAcknowledgement
    public func encodeEvent(_ event: NotificationEvent) throws -> Data
}
```

Decode an internal `WireIngress` with custom `CodingKeys`; parse RFC 3339 using two fresh `ISO8601DateFormatter` instances (`.withInternetDateTime` and `.withInternetDateTime + .withFractionalSeconds`). Require schema version 1, a nonempty title/message, title/message Unicode-scalar counts within the limits, `dedup_key` at most 128 characters without control characters, `createdAt <= now + 300`, and `expiresAt > max(createdAt, now)`. `NotificationSourceID` accepts only `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`.

Define `NotificationDeliveryState` as finite `suppressed`, `queued`, `handedOff`, `failed`; `NotificationRecord` stores the normalized event, immutable delivery plan selected at ingestion, first/last seen, occurrence count, active/ack metadata, and per-channel attempt state. `NotificationHistoryPage` contains at most 100 records plus an optional next cursor. `NotificationEngineSummary` contains configuration, known sources, active count, and bounded recent records. `NotificationSummary` wraps that engine summary and adds finite daemon-derived MQTT/Mac/panel availability plus `panelTokenPresent`; the engine never derives secret presence. Public history and summary DTOs expose no secrets or raw payload.

- [ ] **Step 4: Run focused tests and format the new files**

Run: `./src/scripts/test.sh --filter NotificationModelTests`

Expected: PASS.

Run: `xcrun swift-format format --in-place src/MacTowerCore/NotificationModel.swift tests/MacTowerCoreTests/NotificationModelTests.swift`

Expected: exit 0.

- [ ] **Step 5: Commit the model slice**

```bash
git add src/MacTowerCore/NotificationModel.swift tests/MacTowerCoreTests/NotificationModelTests.swift
git commit -m "feat: add validated notification model"
```

### Task 2: Rules, quiet hours, and finite panel configuration

**Files:**
- Create: `src/MacTowerCore/NotificationConfiguration.swift`
- Create: `src/MacTowerCore/NotificationPolicy.swift`
- Create: `tests/MacTowerCoreTests/NotificationPolicyTests.swift`

**Interfaces:**
- Consumes: `NotificationSourceID`, `NotificationSeverity`, and `NotificationChannel` from Task 1.
- Produces: `NotificationConfiguration`, `NotificationRule`, `NotificationRoute`, `QuietHours`, `NSPanelConfiguration`, `NSPanelPairingStatus`, `AINotificationConfiguration`, `NotificationPolicyEvaluator.evaluate(_:configuration:now:calendar:) -> NotificationPolicyDecision`.

- [ ] **Step 1: Write policy tests for inheritance, overrides, midnight, and DST**

```swift
@Test func unknownSourceUsesGlobalAndOverrideReplacesIt() throws {
    let source = try NotificationSourceID(validating: "weather.outdoor")
    let global = NotificationRule(deliveries: [.warning: .init(channels: [.mqtt])])
    var configuration = NotificationConfiguration(globalRule: global)
    #expect(NotificationPolicyEvaluator().evaluate(event(.warning, source), configuration: configuration, now: noon).channels == [.mqtt])
    configuration.sourceRules[source] = NotificationRule(
        deliveries: [.warning: .init(channels: [.mac, .panel], wakePanel: true)])
    #expect(NotificationPolicyEvaluator().evaluate(event(.warning, source), configuration: configuration, now: noon).channels == [.mac, .panel])
}

@Test func overnightQuietHoursUseLocalCalendarAndCriticalBypassIsExplicit() throws {
    let quiet = try QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
    let calendar = Calendar(identifier: .gregorian).setting(timeZone: try #require(TimeZone(identifier: "Europe/Madrid")))
    // Assert 23:30 and the repeated DST hour are quiet, 12:00 is not,
    // warning is suppressed, and only a route with bypassQuietHours=true passes.
}
```

Also reject missing severity entries with implicit delivery, wake/sound without `.panel`, reminder outside 60...86,400 seconds, cooldown outside 0...86,400, volume outside 0...100, countdown outside 0...1,799, invalid ports, and nonlocal/empty panel hosts.

- [ ] **Step 2: Run policy tests and verify RED**

Run: `./src/scripts/test.sh --filter NotificationPolicyTests`

Expected: compile failure because configuration and evaluator types do not exist.

- [ ] **Step 3: Implement configuration types with empty safe defaults**

```swift
public struct NotificationConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var mqttIngressEnabled: Bool
    public var mqttAcknowledgementEnabled: Bool
    public var globalRule: NotificationRule
    public var sourceRules: [NotificationSourceID: NotificationRule]
    public var panel: NSPanelConfiguration?
    public var ai: AINotificationConfiguration

    public static let disabled = NotificationConfiguration(
        enabled: false,
        mqttIngressEnabled: false,
        mqttAcknowledgementEnabled: false,
        globalRule: .silent,
        sourceRules: [:],
        panel: nil,
        ai: .disabled)
}

public struct NotificationRoute: Codable, Equatable, Sendable {
    public var channels: Set<NotificationChannel>
    public var wakePanel: Bool
    public var panelSound: NSPanelSound?
    public var cooldownSeconds: Int
    public var reminderSeconds: Int?
    public var bypassQuietHours: Bool
}

public enum NSPanelPairingStatus: String, Codable, Equatable, Sendable {
    case pressDone = "press_done"
    case paired
}
```

`NotificationRule.silent` has no delivery entries and no quiet period. `NSPanelConfiguration` contains only `host` and `port` (default 8081), never the token or a caller-controlled token-status flag. `NotificationSummary` reports the daemon-derived `panelTokenPresent`. AI configuration contains typed quota/balance thresholds and a consecutive-failure count in `1...20`; all threshold arrays default empty. Implement `NotificationConfiguration.validated() throws -> NotificationConfiguration`; every replacement and persisted decode must pass through it.

- [ ] **Step 4: Implement pure policy evaluation**

`NotificationPolicyEvaluator` selects `sourceRules[event.sourceID] ?? globalRule`, then the explicit route for the event severity. Missing route means no channels. Determine quiet state from local hour/minute components rather than adding wall-clock seconds, including ranges across midnight. If quiet and bypass is false, return the selected channels as suppressed and no delivery intents. Do not queue `info`/`warning` for the end of quiet hours.

- [ ] **Step 5: Run focused policy tests**

Run: `./src/scripts/test.sh --filter NotificationPolicyTests`

Expected: PASS, including Europe/Madrid DST fixtures.

- [ ] **Step 6: Commit the policy slice**

```bash
git add src/MacTowerCore/NotificationConfiguration.swift src/MacTowerCore/NotificationPolicy.swift tests/MacTowerCoreTests/NotificationPolicyTests.swift
git commit -m "feat: add notification routing policy"
```

### Task 3: Versioned private notification store

**Files:**
- Create: `src/MacTowerCore/NotificationStore.swift`
- Create: `tests/MacTowerCoreTests/NotificationStoreTests.swift`

**Interfaces:**
- Consumes: `PrivateFileStore`, `NotificationConfiguration`, and `NotificationRecord`.
- Produces: `NotificationPersistentState`, `NotificationStateStore`, `FileNotificationStateStore.load()/save(_:)`, and `NotificationStoreError`.

- [ ] **Step 1: Write storage tests**

Create a temporary `PrivateFileStore` and prove: missing file returns `.empty`; round-trip uses sorted keys and seconds-since-epoch; the file is mode `0600`; a symlink is refused; malformed JSON and `version: 2` throw distinct finite errors without rewriting bytes; notification state does not alter `service.json`, `power-control.json`, MQTT password, or account files.

```swift
let store = try FileNotificationStateStore(root: root)
try store.save(.empty)
let restored = try store.load()
#expect(restored.version == 1)
#expect(restored.configuration == .disabled)
#expect(restored.records.isEmpty)
```

- [ ] **Step 2: Run storage tests and verify RED**

Run: `./src/scripts/test.sh --filter NotificationStoreTests`

Expected: compile failure because the store does not exist.

- [ ] **Step 3: Implement the injected store boundary**

```swift
public struct NotificationPersistentState: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var configuration: NotificationConfiguration
    public var knownSources: Set<NotificationSourceID>
    public var records: [NotificationRecord]
}

public protocol NotificationStateStore: Sendable {
    func load() throws -> NotificationPersistentState
    func save(_ state: NotificationPersistentState) throws
}

public struct FileNotificationStateStore: NotificationStateStore, Sendable {
    public static let fileName = "notifications.json"
    public init(root: URL) throws
    public func load() throws -> NotificationPersistentState
    public func save(_ state: NotificationPersistentState) throws
}
```

Read and write only through `PrivateFileStore`; missing data returns `.empty`, malformed and future versions throw, and save rejects any non-current version. Do not silently replace corrupt data.

- [ ] **Step 4: Run focused tests and existing private-store tests**

Run: `./src/scripts/test.sh --filter 'NotificationStoreTests|ServiceCoreTests'`

Expected: PASS.

- [ ] **Step 5: Commit the storage slice**

```bash
git add src/MacTowerCore/NotificationStore.swift tests/MacTowerCoreTests/NotificationStoreTests.swift
git commit -m "feat: persist private notification state"
```

### Task 4: Serialized event engine, retention, and recovery

**Files:**
- Create: `src/MacTowerCore/NotificationEngine.swift`
- Create: `tests/MacTowerCoreTests/NotificationEngineTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3 models, evaluator, and store.
- Produces: actor `NotificationEngine`, `NotificationEffect`, `NotificationDeliveryIntent`, `NotificationActiveChange`, `NotificationRateLimiter`, and engine methods `ingest`, `acknowledge`, `replaceConfiguration`, `markDelivery`, `dueEffects`, `history`, and `stateSummary`.

- [ ] **Step 1: Write transition tests before the engine**

Use an in-memory recording store and fixed dates. Pin:

- persistence happens before effects are returned;
- concurrent ingestion of duplicate IDs produces one durable record and one delivery transition;
- duplicate `event_id` is a no-op;
- matching source/dedup key increments one record;
- severity escalation delivers immediately and cannot downgrade active critical;
- cooldown and reminder boundaries;
- quiet suppression without an ordinary-event flood, plus exactly one still-active critical delivery after quiet hours;
- acknowledgement only accepts active critical and is idempotent;
- expiry clears active retained state;
- 30-day/5,000-record pruning keeps active critical; when all 5,000 slots are active critical, a new distinct event is rejected rather than growing storage;
- 30-per-minute source and 300-per-minute global limits;
- restart restores active critical, but not attempted ordinary deliveries;
- a failed save returns no delivery effect.

```swift
let transition = try await engine.ingest(input, now: now, calendar: calendar)
#expect(transition.compactMap { $0.delivery?.channel } == [.mqtt, .mac])
#expect(store.savedStates.last?.records.count == 1)
_ = try await engine.acknowledge(eventID: input.eventID, actor: .mac, now: later)
#expect((await engine.stateSummary()).activeCriticalCount == 0)
```

- [ ] **Step 2: Run engine tests and verify RED**

Run: `./src/scripts/test.sh --filter NotificationEngineTests`

Expected: compile failure because engine interfaces do not exist.

- [ ] **Step 3: Implement finite transition/effect types**

```swift
public struct NotificationDeliveryIntent: Equatable, Sendable {
    public let eventID: UUID
    public let channel: NotificationChannel
    public let wakePanel: Bool
    public let panelSound: NSPanelSound?
}

public enum NotificationActiveChange: Equatable, Sendable {
    case upsert(NotificationRecord)
    case clear(UUID)
}

public struct NotificationEffect: Equatable, Sendable {
    public let delivery: NotificationDeliveryIntent?
    public let activeChange: NotificationActiveChange?
}
```

- [ ] **Step 4: Implement the actor with save-before-effect ordering**

```swift
public actor NotificationEngine {
    public init(store: any NotificationStateStore) throws
    public func ingest(
        _ input: NotificationIngress, now: Date, calendar: Calendar
    ) throws -> [NotificationEffect]
    public func acknowledge(
        eventID: UUID, actor: NotificationAcknowledgementActor, now: Date
    ) throws -> [NotificationEffect]
    public func dueEffects(now: Date, calendar: Calendar) throws -> [NotificationEffect]
    public func markDelivery(
        eventID: UUID, channel: NotificationChannel, state: NotificationDeliveryState,
        attemptedAt: Date
    ) throws
    public func replaceConfiguration(_ replacement: NotificationConfiguration) throws
    public func configuration() -> NotificationConfiguration
    public func markPanelSoundAttempted(eventID: UUID, attemptedAt: Date) throws -> Bool
    public func history(limit: Int, before: Date?) -> NotificationHistoryPage
    public func stateSummary() -> NotificationEngineSummary
}
```

Keep actor state as one `NotificationPersistentState`; copy, mutate, validate/prune, call `store.save(candidate)`, then assign and return effects. Persist the selected `NotificationDeliveryPlan` before returning effects, so retries and recovery do not silently adopt later rule changes. Source/global rate limiting uses rolling timestamps in memory and happens before durable mutation. Cap history at 5,000 records and each history page at 100; prune expired/acknowledged/ordinary history first and reject a new distinct event with a finite capacity error if all slots are unexpired active critical. `markPanelSoundAttempted` persists a dedicated timestamp before the service performs the HTTP request and returns false on every later call for that event.

- [ ] **Step 5: Run engine and policy tests**

Run: `./src/scripts/test.sh --filter 'NotificationEngineTests|NotificationPolicyTests|NotificationStoreTests'`

Expected: PASS.

- [ ] **Step 6: Commit the engine slice**

```bash
git add src/MacTowerCore/NotificationEngine.swift tests/MacTowerCoreTests/NotificationEngineTests.swift
git commit -m "feat: add durable notification engine"
```

### Task 5: MQTT topic parser and publication planner

**Files:**
- Create: `src/MacTowerCore/NotificationMQTTPlanner.swift`
- Create: `tests/MacTowerCoreTests/NotificationMQTTTests.swift`

**Interfaces:**
- Consumes: `NotificationWireCodec`, records/effects, `NotificationConfiguration`, and `MQTTPublication`.
- Produces: `NotificationMQTTMessage`, `NotificationMQTTPlanner.parse(topic:payload:retained:now:configuration:)`, `eventPublication`, `panelPublication`, `activePublication`, `clearActivePublication`, and `availabilityPublication`.

- [ ] **Step 1: Write parser/planner tests**

Pin exact topics, QoS, retain flags, sorted-key payloads, source extraction, acknowledgement parsing, and refusal of malformed topics. Explicitly test live retained writes, retained replay, `inbox/a/b`, wildcard characters, own `/events` payload fed to parse, disabled ingress/ack, oversized topic/payload, and ack of a non-UUID.

```swift
let planner = NotificationMQTTPlanner(topicPrefix: "tower/site")
let parsed = try planner.parse(
    topic: "tower/site/notifications/inbox/weather",
    payload: ingressJSON,
    retained: false,
    now: now,
    configuration: enabledConfiguration)
#expect(parsed == .ingress(expectedInput))
#expect(planner.eventPublication(record).retain == false)
#expect(planner.activePublication(record).retain == true)
#expect(planner.clearActivePublication(record.event.eventID).payload.isEmpty)
```

- [ ] **Step 2: Run MQTT planner tests and verify RED**

Run: `./src/scripts/test.sh --filter NotificationMQTTTests`

Expected: compile failure because the planner does not exist.

- [ ] **Step 3: Implement strict namespace parsing and publications**

Parse only these suffixes relative to the exact normalized topic prefix:

```swift
public enum NotificationMQTTMessage: Equatable, Sendable {
    case ingress(NotificationIngress)
    case acknowledgement(NotificationAcknowledgement)
}
```

`inbox` must have exactly one source segment; `ack` has no suffix. Return a finite error for every other topic. Refuse retained before decoding. `events` and `panel` publications are QoS 1/non-retained; `active` and `availability` are QoS 1/retained; active tombstones use empty payload. `panelPublication(_:acknowledgementEnabled:)` includes a daemon-derived boolean that the blueprint uses to decide whether to expose Acknowledge. Public payload includes schema version, ID, source, severity, title/message, timestamps, occurrence count, and active state only—never configuration, labels/emails, raw provider responses, tokens, or channel errors.

- [ ] **Step 4: Run planner tests plus existing MQTT planner tests**

Run: `./src/scripts/test.sh --filter 'NotificationMQTTTests|WindowMQTTTests|PublicationTests'`

Expected: PASS with no existing topic changes.

- [ ] **Step 5: Commit the MQTT contract slice**

```bash
git add src/MacTowerCore/NotificationMQTTPlanner.swift tests/MacTowerCoreTests/NotificationMQTTTests.swift
git commit -m "feat: add notification MQTT contract"
```

### Task 6: Safe NSPanel Pro local client

**Files:**
- Modify: `src/MacTowerCore/ServiceConfiguration.swift`
- Create: `src/MacTowerTransport/NSPanelClient.swift`
- Create: `tests/MacTowerCoreTests/NSPanelClientTests.swift`

**Interfaces:**
- Consumes: `NSPanelConfiguration`, `NSPanelSound`, existing local IPv4 ranges, and Foundation networking.
- Produces: `NSPanelAddressResolving`, `NSPanelHTTPDataLoading`, `NSPanelClient.live`, `pair()`, `wake(token:)`, `play(sound:token:)`, transport `NSPanelPairingResult`, and finite `NSPanelClientError`.

- [ ] **Step 1: Write request, response, and hostile-network tests**

Use fake resolver/loader values to assert:

- `GET /open-api/v1/rest/bridge/access_token?app_name=MacTower` returns `.pressDone` for API error 401 and `.paired(token)` for error 0;
- wake is `POST /open-api/v1/rest/screen/display/wake-up` with no body;
- sound is `POST /open-api/v1/rest/hardware/speaker` with exactly `{"type":"play_sound","sound":{"name":"alert1","volume":50,"countdown":3}}`;
- only the resolved numeric private IPv4 appears in the URL;
- public IPv4, IPv6-only, mixed public/private answers, redirect, non-HTTP response, body over 64 KiB, invalid JSON, API error, and timeout fail;
- error descriptions never contain the bearer token or response body.

- [ ] **Step 2: Run NSPanel tests and verify RED**

Run: `./src/scripts/test.sh --filter NSPanelClientTests`

Expected: compile failure because the client does not exist.

- [ ] **Step 3: Expose one reusable local-address predicate**

Add this bounded API without changing existing MQTT validation behavior:

```swift
extension IPv4CIDR {
    public static func isLocalHostAddress(_ value: String) -> Bool {
        guard let address = parseHostAddress(value) else { return false }
        return localAddressRanges.contains { address >= $0.start && address <= $0.end }
    }
}
```

- [ ] **Step 4: Implement address pinning and no-redirect loading**

Resolve with `getaddrinfo(AF_INET)`, require at least one result and require every result to be local, select the sorted first numeric address, and construct `http://<numeric-ip>:<configured-port>`. Re-resolve before every operation. A production `URLSessionTaskDelegate` returns `nil` from redirection callbacks; the client also rejects any 3xx status. Set connect/resource timeouts, `Cache-Control: no-store`, `Content-Type: application/json`, and `Authorization: Bearer <token>` only for authenticated calls.

The official response envelope is:

```swift
public enum NSPanelPairingResult: Equatable, Sendable {
    case pressDone
    case paired(token: String)
}

private struct Response<Value: Decodable>: Decodable {
    let error: Int
    let data: Value
    let message: String
}
private struct TokenData: Decodable { let token: String? }
```

Never surface `message` outside the client; map it to finite codes.

- [ ] **Step 5: Run focused tests and transport tests**

Run: `./src/scripts/test.sh --filter 'NSPanelClientTests|MQTTDockerIntegrationTests'`

Expected: PASS; the Docker suite may skip when its environment variable is absent.

- [ ] **Step 6: Commit the panel client slice**

```bash
git add src/MacTowerCore/ServiceConfiguration.swift src/MacTowerTransport/NSPanelClient.swift tests/MacTowerCoreTests/NSPanelClientTests.swift
git commit -m "feat: add safe NSPanel local client"
```

### Task 7: Daemon notification service and MQTT runtime integration

**Files:**
- Create: `src/MacTowerDaemon/NotificationService.swift`
- Modify: `src/MacTowerTransport/HomeAssistantMQTTPublisher.swift`
- Modify: `src/MacTowerDaemon/DaemonNetworkRuntime.swift`
- Modify: `src/MacTowerDaemon/MacTowerDaemon.swift`
- Modify: `src/MacTowerDaemon/DaemonLifecycle.swift`
- Modify: `tests/MacTowerCoreTests/MQTTDockerIntegrationTests.swift`
- Create: `tests/MacTowerDaemonTests/NotificationServiceTests.swift`

**Interfaces:**
- Consumes: Tasks 1–6, `HomeAssistantMQTTPublisher`, `PrivateFileStore`, and daemon lifecycle.
- Produces: `NotificationService`, `NotificationServiceControlling`, `NotificationStopping`, `NotificationMQTTPublishing`, `NotificationUserAgent`, publisher ingress/ack callbacks, recovery/reminder lifecycle, and daemon channel status.

- [ ] **Step 1: Write orchestration tests with fake adapters**

Prove event save precedes publish, MQTT and Mac failures do not block panel work, panel text handoff precedes wake/sound, failed text handoff prevents wake/sound, sound is marked attempted before HTTP, an ambiguous wake has at most one bounded retry while sound has none, disconnect queues retryable work, reconnect republishes availability/active state, user-agent registration drains unexpired in-process Mac work, daemon restart restores only active critical, corrupt notification state degrades only this subsystem, and stop cancels reminders before network teardown.

```swift
protocol NotificationUserAgent: Sendable {
    var id: UUID { get }
    func deliver(_ request: MacNotificationDelivery) async -> NotificationDeliveryState
    func remove(eventID: UUID) async
}

protocol NotificationMQTTPublishing: Sendable {
    func publish(_ publications: [MQTTPublication]) async throws
}
```

- [ ] **Step 2: Run daemon notification tests and verify RED**

Run: `./src/scripts/test.sh --filter NotificationServiceTests`

Expected: compile failure because daemon orchestration does not exist.

- [ ] **Step 3: Extend MQTT transport with bounded callbacks**

Add optional parameters to the existing `connect` signature without breaking callers:

```swift
onNotificationIngress: (@Sendable (String, Data, Bool) -> Void)? = nil,
onNotificationAcknowledgement: (@Sendable (String, Data, Bool) -> Void)? = nil
```

Subscribe with clean session, `retainAsPublished: true`, and `.doNotSend` to `<prefix>/notifications/inbox/+` and `<prefix>/notifications/ack` only when callbacks are supplied. Before copying payload, enforce the 16 KiB maximum and an exact bounded topic shape. Keep existing HA birth and window-command behavior unchanged.

- [ ] **Step 4: Implement `NotificationService` ownership**

```swift
actor NotificationService {
    init(root: URL, panelClient: NSPanelClient = .live) throws
    func start() async throws
    func stop() async
    func setMQTTPublisher(_ publisher: (any NotificationMQTTPublishing)?) async
    func registerUserAgent(_ agent: (any NotificationUserAgent)?) async
    func receiveMQTT(topic: String, payload: Data, retained: Bool, now: Date) async
    func acknowledge(eventID: UUID, actor: NotificationAcknowledgementActor) async throws
    func replaceConfiguration(_ configuration: NotificationConfiguration) async throws
    func configuration() async -> NotificationConfiguration
    func summary() async -> NotificationSummary
    func history(limit: Int, before: Date?) async -> NotificationHistoryPage
}
```

Open `FileNotificationStateStore`, keep the NSPanel bearer in `nspanel-token`, and never put it into status/config DTOs. The service executes engine effects independently and records per-channel results. A continuous-clock task asks `dueEffects` at the next bounded deadline; no busy loop. Invalid input increments a capped diagnostic counter and logs only a finite code.

Introduce a narrow `NotificationServiceControlling` protocol for the runtime and later management layer. A notification-store initialization/version/corruption error is isolated at the daemon composition boundary: log only a finite code, leave the service reference absent, expose notification status as unavailable, and keep AI collection, HTTP, ordinary MQTT sensors, window control, and power control running. Do not replace, truncate, or migrate the bad file implicitly.

- [ ] **Step 5: Wire the service into daemon/network lifecycle**

Attempt to construct one `NotificationService` in `MacTowerDaemon.run`, pass the optional service to `DaemonNetworkRuntime` and later XPC work, start it before network subscriptions, and stop it before the network publisher. Extend `DaemonLifecycle` with an optional notification stopper and verify shutdown ordering. In the collection loop keep notification observation deferred to Task 10. On MQTT connect set the publisher, register ingress/ack callbacks only when the service is available, publish notification availability and active recovery; on disconnect clear the publisher without clearing durable active state. A missing service leaves existing MQTT subscriptions and publications unchanged.

- [ ] **Step 6: Extend real-broker coverage**

Add a Docker test that publishes retained and live ingress, receives only the live callback, proves QoS 1 outbound `events` is non-retained, active is retained, ack is live-only, reconnect does not resume an old session, and publishing the outbound event into the observer cannot re-enter inbox handling. Keep the existing window-control scenario intact.

- [ ] **Step 7: Run daemon, transport, and Docker checks**

Run: `./src/scripts/test.sh --filter 'NotificationServiceTests|MQTTDockerIntegrationTests'`

Expected: unit PASS; Docker tests skip without `MACTOWER_MQTT_TEST_PORT`.

Run: `make test-mqtt-docker`

Expected: PASS against the temporary Mosquitto container.

- [ ] **Step 8: Commit the daemon runtime slice**

```bash
git add src/MacTowerDaemon/NotificationService.swift src/MacTowerTransport/HomeAssistantMQTTPublisher.swift src/MacTowerDaemon/DaemonNetworkRuntime.swift src/MacTowerDaemon/MacTowerDaemon.swift src/MacTowerDaemon/DaemonLifecycle.swift tests/MacTowerCoreTests/MQTTDockerIntegrationTests.swift tests/MacTowerDaemonTests/NotificationServiceTests.swift
git commit -m "feat: run notification delivery in daemon"
```

### Task 8: Authenticated management and macOS Notification Center bridge

**Files:**
- Modify: `src/MacTowerCore/ManagementContract.swift`
- Modify: `src/MacTowerCore/WindowControlContract.swift`
- Modify: `src/MacTowerDaemon/DaemonManagementHandler.swift`
- Modify: `src/MacTowerDaemon/DaemonXPCServer.swift`
- Modify: `src/MacTowerDaemon/NotificationService.swift`
- Modify: `src/MacTowerApp/Services/DaemonClient.swift`
- Modify: `src/MacTowerApp/Services/WindowAgentBridge.swift`
- Modify: `src/MacTowerApp/App/AppServices.swift`
- Create: `src/MacTowerApp/Services/MacNotificationController.swift`
- Create: `tests/MacTowerAppTests/MacNotificationControllerTests.swift`
- Create: `tests/MacTowerDaemonTests/NotificationManagementTests.swift`

**Interfaces:**
- Consumes: `NotificationService`, existing management envelope, reverse XPC connection, `XPCReplyLedger`, and UserNotifications.
- Produces: finite notification management operations/DTOs, `MacNotificationDelivery`, reverse methods `deliverUserNotification`/`removeUserNotification`, and observable `MacNotificationController` authorization state.

- [ ] **Step 1: Write finite management-contract tests**

Add operations:

```swift
case replaceNotificationConfiguration = "replace_notification_configuration"
case notificationHistory = "notification_history"
case acknowledgeNotification = "acknowledge_notification"
case pairNSPanel = "pair_nspanel"
case clearNSPanelToken = "clear_nspanel_token"
case testNotificationChannel = "test_notification_channel"
```

Test payload size bounds, history limit `1...100`, UUID acknowledgement, finite test channel, the raw panel token never encoded in `DaemonStatus`, and older status JSON decoding notification summary as `nil` rather than a false healthy state.

- [ ] **Step 2: Write fake Notification Center and reverse-XPC tests**

Inject this boundary:

```swift
enum MacNotificationAuthorization: Equatable, Sendable {
    case notDetermined, denied, authorized
}

struct MacNotificationRequest: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let categoryIdentifier: String?
}

protocol UserNotificationCenterServing: Sendable {
    func authorizationStatus() async -> MacNotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func add(_ request: MacNotificationRequest) async throws
    func remove(identifier: String) async
}
```

Assert permission denial returns failed, `eventID.uuidString` is the system identifier, repeated delivery replaces the same request, only critical registers the fixed Acknowledge action, user action calls daemon acknowledgement once, disconnect rejects late XPC delivery, and notification body remains literal text.

- [ ] **Step 3: Run management/app tests and verify RED**

Run: `./src/scripts/test.sh --filter 'NotificationManagementTests|MacNotificationControllerTests'`

Expected: compile failure because contracts and controller are absent.

- [ ] **Step 4: Add management DTOs and compose status**

Use exact bounded requests:

```swift
public struct NotificationHistoryRequest: Codable, Sendable {
    public let limit: Int
    public let before: Date?
}
public struct AcknowledgeNotificationRequest: Codable, Sendable {
    public let eventID: UUID
}
public enum NotificationTestChannel: String, Codable, CaseIterable, Sendable {
    case mac, panelText = "panel_text", panelWake = "panel_wake", panelSound = "panel_sound"
}
```

`MacNotificationDelivery` is the bounded Task 1 DTO; do not create a second wire shape. Extend `DaemonStatus` with optional `notificationSummary`. `DaemonManagementHandler` receives an optional `NotificationServiceControlling`; notification operations return a finite unavailable error when startup was isolated, while unrelated operations remain usable. Extend `NotificationService` with `pairNSPanel() -> NSPanelPairingStatus`, `clearNSPanelToken()`, and `testChannel(_:)`. Pairing maps Task 6 `.pressDone` directly; for `.paired(token:)`, it returns `.paired` only after the token has been durably written. Clearing removes only `nspanel-token` and updates daemon-derived `panelTokenPresent`.

- [ ] **Step 5: Extend the persistent reverse XPC protocol**

Add to `MacTowerWindowAgentXPCProtocol`:

```swift
func deliverUserNotification(
    _ request: Data,
    withReply reply: @escaping @Sendable (Data?, String?) -> Void)
func removeUserNotification(
    _ request: Data,
    withReply reply: @escaping @Sendable (Data?, String?) -> Void)
```

Register `WindowAgentPeer` with `NotificationService` only after a valid window-agent heartbeat on the authenticated persistent connection. Invalidation unregisters the same peer ID. Enforce 16 KiB request and 4 KiB response bounds. Ephemeral management connections never become notification agents.

- [ ] **Step 6: Implement `MacNotificationController`**

Wrap `UNUserNotificationCenter`, register one category/action, and expose explicit `requestAuthorization()`. `deliver` uses a stable identifier and no attachment/URL/user-supplied category. Delegate action handling accepts only the fixed action and a UUID request identifier, then calls `DaemonClient.acknowledgeNotification`.

- [ ] **Step 7: Extend `DaemonClient` and app composition**

Add published summary/history/pairing state and bounded async methods for all operations. Inject one `MacNotificationController` into `WindowAgentBridge`; the endpoint forwards reverse XPC calls on `@MainActor`. Preserve existing window heartbeats, cancellation, and reconnect logic.

- [ ] **Step 8: Run focused and existing XPC/window tests**

Run: `./src/scripts/test.sh --filter 'NotificationManagementTests|MacNotificationControllerTests|WindowBridgeSessionTests|WindowRoutingTests|ManagementTests'`

Expected: PASS, including existing trust and stale-session cases.

- [ ] **Step 9: Commit the authenticated Mac bridge slice**

```bash
git add src/MacTowerCore/ManagementContract.swift src/MacTowerCore/WindowControlContract.swift src/MacTowerDaemon/DaemonManagementHandler.swift src/MacTowerDaemon/DaemonXPCServer.swift src/MacTowerDaemon/NotificationService.swift src/MacTowerApp/Services/DaemonClient.swift src/MacTowerApp/Services/WindowAgentBridge.swift src/MacTowerApp/App/AppServices.swift src/MacTowerApp/Services/MacNotificationController.swift tests/MacTowerAppTests/MacNotificationControllerTests.swift tests/MacTowerDaemonTests/NotificationManagementTests.swift
git commit -m "feat: deliver notifications through trusted Mac agent"
```

### Task 9: Home Assistant blueprint and acknowledgement bridge

**Files:**
- Create: `homeassistant/blueprints/automation/mactower/notifications.yaml`
- Create: `tests/homeassistant_blueprint.sh`
- Modify: `Makefile`

**Interfaces:**
- Consumes: panel event payload and ack topics from Task 5.
- Produces: one importable automation blueprint with `panel_topic`, `ack_topic`, and actual `notify_action` inputs.

- [ ] **Step 1: Add a failing blueprint validation script**

The script loads YAML with Ruby/Psych while permitting the scalar `!input` tag, then asserts:

```ruby
require "yaml"

class InputReference
    attr_reader :value
    def init_with(coder)
        @value = coder.scalar
    end
end

Psych.add_tag("!input", InputReference)
path = File.expand_path("../homeassistant/blueprints/automation/mactower/notifications.yaml", __dir__)
source = File.read(path, encoding: "UTF-8")
document = YAML.safe_load(source, permitted_classes: [InputReference], aliases: false)
abort "wrong domain" unless document.dig("blueprint", "domain") == "automation"
inputs = document.dig("blueprint", "input") || {}
abort "missing inputs" unless %w[panel_topic ack_topic notify_action].all? { |key| inputs.key?(key) }
abort "missing mqtt trigger" unless source.include?("trigger: mqtt")
abort "retained ack" if source.match?(/retain:\s*true/)
abort "unsafe command" if source.match?(/shell_command|command_line|rest_command/)
```

Add `test-homeassistant-blueprint` to `.PHONY`, `help`, and `check`.

- [ ] **Step 2: Run the validator and verify RED**

Run: `bash tests/homeassistant_blueprint.sh`

Expected: FAIL because the blueprint is missing.

- [ ] **Step 3: Create the exact two-trigger blueprint**

Use one MQTT trigger for the configured panel topic and one `mobile_app_notification_action` event trigger. For notification events, call the user-supplied action name with title/message and `tag: "{{ trigger.payload_json.event_id }}"`. Add the action only when severity is critical and `acknowledgement_enabled` is true:

```yaml
actions:
  - action: "MACTOWER_ACK_{{ trigger.payload_json.event_id }}"
    title: Acknowledge
```

For action events, require the identifier to match `^MACTOWER_ACK_[0-9a-fA-F-]{36}$`, strip the prefix, require the remainder to match a UUID pattern, and publish:

```yaml
topic: !input ack_topic
qos: 1
retain: false
payload: >-
  {"schema_version":1,"event_id":"{{ event_id }}"}
```

Do not embed a device/entity name, broker credential, webhook, URL, or shell command.

- [ ] **Step 4: Run the blueprint and MQTT tests**

Run: `make test-homeassistant-blueprint`

Expected: PASS.

Run: `./src/scripts/test.sh --filter NotificationMQTTTests`

Expected: PASS with the same topic/payload contract used by the YAML.

- [ ] **Step 5: Commit the Home Assistant bridge**

```bash
git add homeassistant/blueprints/automation/mactower/notifications.yaml tests/homeassistant_blueprint.sh Makefile
git commit -m "feat: add Home Assistant panel notification blueprint"
```

### Task 10: AI sensor transition producers

**Files:**
- Modify: `src/MacTowerCore/SnapshotStore.swift`
- Create: `src/MacTowerCore/AINotificationDetector.swift`
- Modify: `src/MacTowerDaemon/DaemonNetworkRuntime.swift`
- Create: `tests/MacTowerCoreTests/AINotificationDetectorTests.swift`
- Modify: `tests/MacTowerCoreTests/ServiceCoreTests.swift`

**Interfaces:**
- Consumes: old/new `StoredSnapshot` values and typed AI thresholds from Task 2.
- Produces: backward-compatible `consecutiveFailures`, stable internal source IDs, and `AINotificationDetector.events(previous:current:configuration:now:) -> [NotificationIngress]`.

- [ ] **Step 1: Write exhaustive transition tests**

Pin authorization-required/restored transitions, threshold crossing only from above to at-or-below, no event for missing quota, no event for repeated same snapshot, fresh quota reset only when observed time advances and reset time/remaining value advance, exact Decimal DeepSeek comparison by currency, consecutive failure boundary/recovery, Claude identical statusline replay, and stable source IDs independent of label/email.

```swift
let events = try detector.events(
    previous: [stored(remaining: 21, observedAt: t0)],
    current: [stored(remaining: 19, observedAt: t1)],
    configuration: quotaThreshold(20),
    now: t1)
#expect(events.count == 1)
#expect(events[0].sourceID.rawValue.hasPrefix("ai.codex."))
```

- [ ] **Step 2: Run detector tests and verify RED**

Run: `./src/scripts/test.sh --filter AINotificationDetectorTests`

Expected: compile failure because detector/failure count are absent.

- [ ] **Step 3: Add backward-compatible failure counts**

Extend `StoredSnapshot` with `consecutiveFailures`. `recordSuccess` stores 0; `recordFailure` increments with saturation. Implement custom decoding so old `snapshots.json` lacking the field reads 0. Preserve all existing fields and publication behavior.

- [ ] **Step 4: Implement stable source IDs and exact transitions**

Create internal IDs from provider/account/metric identity, never label/email. Bound long IDs with a readable prefix plus a deterministic FNV-1a 64-bit hex suffix so the result always validates and remains stable across launches. Convert validated `DecimalString` with `Decimal(string:locale: Locale(identifier: "en_US_POSIX"))`; never compare balance as `Double`.

Quota reset requires `current.observedAt > previous.observedAt`, `current.resetsAt > previous.resetsAt`, and `current.remainingPercent > previous.remainingPercent`. Merely reaching wall-clock `resetsAt` produces nothing. Claude repeated observations with equal provider quota data produce nothing.

- [ ] **Step 5: Feed fresh collection transitions into the engine**

In `runCollectionLoop`, capture entries before collection, collect, capture after, call the detector with current notification AI configuration, and ingest each generated event. Detection failure logs only a finite code and does not block snapshot persistence or sensor publication.

- [ ] **Step 6: Run detector and existing sensor tests**

Run: `./src/scripts/test.sh --filter 'AINotificationDetectorTests|AISensorParserTests|ServiceCoreTests|PublicationTests'`

Expected: PASS, including decoding old snapshot fixtures.

- [ ] **Step 7: Commit the AI producer slice**

```bash
git add src/MacTowerCore/SnapshotStore.swift src/MacTowerCore/AINotificationDetector.swift src/MacTowerDaemon/DaemonNetworkRuntime.swift tests/MacTowerCoreTests/AINotificationDetectorTests.swift tests/MacTowerCoreTests/ServiceCoreTests.swift
git commit -m "feat: emit AI sensor notification transitions"
```

### Task 11: Settings, history, menu, and explicit channel tests

**Files:**
- Create: `src/MacTowerApp/Views/NotificationsSettingsView.swift`
- Create: `src/MacTowerApp/Views/NotificationHistoryView.swift`
- Modify: `src/MacTowerApp/Views/SettingsView.swift`
- Modify: `src/MacTowerApp/Views/MenuBarView.swift`
- Modify: `src/MacTowerApp/App/MacTowerApp.swift`
- Create: `tests/MacTowerAppTests/NotificationPresentationTests.swift`

**Interfaces:**
- Consumes: `DaemonClient`, `MacNotificationController`, configuration/status/history DTOs, finite sound/test-channel enums.
- Produces: Notifications settings tab, global/source rule editors, quiet-hour editor, AI thresholds, permission/pairing controls, history, active count, acknowledgement, and separate Mac/panel-text/wake/sound tests.

- [ ] **Step 1: Write presentation-state tests**

Extract formatting and pending-state decisions into small pure helpers and test: unknown service is not rendered healthy, token absence differs from panel offline, `handedOff` never says “read”, denied Notification Center shows an actionable permission message, active critical count pluralization, rule inheritance label, pairing `.pressDone` instructions, and every explicit test button maps to one finite test channel.

- [ ] **Step 2: Run app presentation tests and verify RED**

Run: `./src/scripts/test.sh --filter NotificationPresentationTests`

Expected: compile failure because the views/helpers do not exist.

- [ ] **Step 3: Add the Notifications settings tab**

Compose focused sections:

```swift
NotificationsSettingsView(
    daemon: daemon,
    macNotifications: macNotifications
)
.tabItem { Label("Notifications", systemImage: "bell") }
```

Provide master, ingress, and ack toggles; global rule; discovered sources with full overrides; per-severity channel matrix; daily quiet start/end and critical bypass; AI quota/balance/failure thresholds; MQTT topic/ACL guidance; macOS authorization request/System Settings link; panel host/port, two-step pairing, clear token; and four independent test buttons. Disable controls while the matching request is pending and reconcile from daemon-confirmed status after every response.

- [ ] **Step 4: Add bounded history and menu surfaces**

`NotificationHistoryView` requests at most 100 rows/page, filters locally within loaded pages, displays finite channel states, and acknowledges only active critical. `MenuBarView` shows active count, up to three recent records, Acknowledge, and Open Notifications; it does not fetch unbounded history on every menu render. Pass `MacNotificationController` through `MacTowerApp`/`SettingsView` composition.

- [ ] **Step 5: Run app tests and build the app target**

Run: `./src/scripts/test.sh --filter 'NotificationPresentationTests|MacNotificationControllerTests|PowerModePresentationTests|WindowBridgeSessionTests'`

Expected: PASS.

Run: `swift build --target MacTowerApp`

Expected: PASS with no daemon installation or notification authorization prompt.

- [ ] **Step 6: Commit the UI slice**

```bash
git add src/MacTowerApp/Views/NotificationsSettingsView.swift src/MacTowerApp/Views/NotificationHistoryView.swift src/MacTowerApp/Views/SettingsView.swift src/MacTowerApp/Views/MenuBarView.swift src/MacTowerApp/App/MacTowerApp.swift tests/MacTowerAppTests/NotificationPresentationTests.swift
git commit -m "feat: add notification settings and history UI"
```

### Task 12: Security docs, operational checks, and full acceptance gate

**Files:**
- Modify: `README.md`
- Modify: `SECURITY.md`
- Modify: `docs/architecture.md`
- Modify: `tests/mqtt_docker_integration.sh`
- Modify: `Makefile`

**Interfaces:**
- Consumes: all completed notification surfaces.
- Produces: accurate setup/ACL/pairing/limitations documentation and final automated evidence.

- [ ] **Step 1: Update public documentation from verified behavior**

Document:

- exact inbox/event/panel/active/ack topics and JSON example;
- ingress/ack opt-ins and broker ACL identities;
- Home Assistant blueprint import and explicit `notify.mobile_app_*` selection;
- two-call physical NSPanel pairing, default port, plain-HTTP LAN risk, recommended trusted IoT network, supported sound names, and token reset behavior;
- macOS authorization/logout behavior and honest `handed_off` semantics;
- global/source rules, quiet hours, history limits, AI transition rules, and lack of battery producer;
- `make test-homeassistant-blueprint`, `make test-mqtt-docker`, reinstall requirement for changed pinned XPC hashes, and manual live checks.

Update SECURITY.md so MQTT ingress and ack join window movement as explicit state-changing surfaces, with retained rejection, ACL assumptions, size/rate limits, and acknowledgement impact. State that notification text is deliberately published only on selected notification topics, not sensors/discovery/logs.

- [ ] **Step 2: Strengthen the Docker script’s wire assertions**

After Swift integration tests, use `mosquitto_sub` to prove active is retained, live event is not retained to a fresh subscriber, and ack/inbox retained messages did not create a new outbound event. Update the PASS line to name notification coverage without removing existing window-control evidence.

- [ ] **Step 3: Run formatting and diff review**

Run: `make format`

Expected: exit 0.

Run: `git diff --check && git status --short`

Expected: no whitespace errors; only intended notification/docs changes are present.

- [ ] **Step 4: Run the complete automated gate**

Run: `make check`

Expected: build, all Swift tests, CLI/dry-run tests, strict formatting, plist validation, shell syntax, and blueprint validation PASS.

Run: `make test-mqtt-docker`

Expected: PASS with a temporary local Mosquitto broker, including notification ingress/outbound/ack/reconnect/retained behavior.

- [ ] **Step 5: Review sensitive output and package changes**

Run:

```bash
git diff -- Package.swift Package.resolved
rg -n "Bearer |nspanel-token|mqtt-password|title|message" src README.md SECURITY.md
```

Expected: no new dependency; bearer/token values never enter logs or public status; title/message appear only in intended notification model/UI/publication code and documentation.

- [ ] **Step 6: Commit the documentation and acceptance slice**

```bash
git add README.md SECURITY.md docs/architecture.md tests/mqtt_docker_integration.sh Makefile
git commit -m "docs: document notification delivery and security"
```

- [ ] **Step 7: Record manual acceptance as unrun until real systems are connected**

After explicit `make install`, manually verify Notification Center allow/deny, duplicate/expired MQTT input, source/global rules, quiet hours, panel text, wake, each supported sound selected for use, acknowledgement from Mac and NSPanel, broker/HA/panel outages, logout/login, daemon restart, and absence of tokens/text in ordinary logs and LAN sensor endpoints. These observations are separate evidence and must not be reported PASS until performed on the real Mac, Home Assistant instance, and NSPanel Pro.
