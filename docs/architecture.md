# Architecture

## Components

| Component | Context | Responsibility |
| --- | --- | --- |
| `MacTowerApp` | Logged-in user | Menu/settings, login-item preference, provider setup, notification history/permission UI, and short-lived management plus persistent duplex reverse XPC connections. |
| `MacTowerCore` | Shared | Public sensor and private notification models, provider parsers/clients, policy/storage boundaries, HTTP routing, MQTT planning, management DTOs, and validation. |
| `MacTowerTransport` | Root daemon | SwiftNIO HTTP server and MQTTNIO publisher. |
| `MacTowerWindowControl` | Logged-in user | Display topology, session eligibility, bounded Accessibility adapter and a single app-lifetime window controller. |
| `MacTowerPowerControl` | Root daemon | Versioned mode storage, serialized assertion state machine, and the public IOKit assertion adapter. |
| `MacTowerDaemon` | Root LaunchDaemon | Account registry, polling, snapshots, Codex processes, XPC service, HTTP, and MQTT. |
| `mac-tower-claude-bridge` | Claude user's statusline | Filters Claude's stdin JSON into one account snapshot without reading credentials. |

Sources live under `src/`, tests under `tests/`, and SwiftPM resolves exact top-level SwiftNIO and MQTTNIO versions in `Package.resolved`.

## Data flow

```text
Codex app-server (one CODEX_HOME/account) ─┐
DeepSeek /user/balance + root-held key ────┼─> SnapshotStore ─> HTTP GET
Claude user statusline snapshot ───────────┘                └─> MQTT + HA Discovery

Menu bar app ── UID + app cdhash ──> finite XPC service
Menu bar app <─ daemon cdhash ────── root LaunchDaemon
Local GUI ─> authenticated XPC ─> root assertion owner ─> IOKit

Home Assistant button ─> MQTT command router ─> pinned duplex XPC ─> user WindowController ─> AX window

MQTT inbox ─> validation/rate limit ─> durable NotificationEngine ─┬─> MQTT event
AI snapshot transition ───────────────────────────────────────────┤
                                                                 ├─> reverse XPC ─> Notification Center
                                                                 └─> HA panel text + NSPanel wake/sound
Home Assistant acknowledgement ─> MQTT ack ─> durable inactive state + retained tombstone
```

Codex and DeepSeek are collected on the configured interval, with a minimum of 60 seconds and a default of five minutes. Failed collections preserve the last snapshot and record the last attempt and classified failure. A reset timestamp does not mutate or zero usage; only a new provider observation does.

Claude is event-driven. Claude Code sends statusline JSON to the wrapper, which gives the original statusline command the same stdin and sends a filtered copy to the bridge. Repeated identical quota data retains the prior observation timestamp, so a statusline redraw is not misrepresented as a new provider poll.

## Account isolation

Each Codex registration maps to a validated directory below the daemon's `codex` root. The daemon invokes the pinned installed Codex binary with only that `CODEX_HOME` and a fixed system `PATH`. OAuth operations are serialized. The official client owns its credential file and refresh lifecycle; MacTower never copies a refresh token from another app.

Claude multi-account support uses explicitly chosen, separate `CLAUDE_CONFIG_DIR` values. MacTower does not scan for profiles. DeepSeek registrations map a stable account ID to a separately stored key filename.

## Privilege and IPC

The app cannot access the root secret store directly. Account management uses a serialized envelope decoding to finite operations. Window control adds typed registration/heartbeat and opt-in methods plus a finite reverse callback; each accepted connection owns its own peer identity and invalidation handling.

The installer applies hardened-runtime ad-hoc signing and records app/daemon cdhash values. The daemon configures its listener with the app requirement and separately checks the caller's effective UID. The client configures its connection with the daemon requirement. Updating either executable therefore requires reinstalling the trust manifest.

This design is appropriate for a local OSS build, not a substitute for Developer ID signing and notarization.

## Power control

`PowerControlService` is created once by the root daemon and is injected into both status/mutation routing and daemon shutdown. It serializes every transition, persists a versioned finite `PowerMode`, and owns at most the assertion handles needed for the applied mode. Tests use an injected backend; only daemon construction creates `IOKitPowerAssertionBackend`.

Normal mode owns no assertion. Keep-Mac-awake maps to the public idle-system-sleep assertion; keep-Mac-and-displays-awake maps to the public idle-display-sleep assertion. Transitions acquire the new assertion before releasing the old one. Requested, persisted, and applied modes remain separate so storage, creation, and release failures cannot be mistaken for success. On SIGTERM/SIGINT, assertion release runs before network shutdown. The saved mode is not changed by shutdown, so a later daemon start restores it.

The app sends a single finite mutation over the existing mutually pinned XPC connection and never retries it automatically. A three-second reply ledger bounds disconnects and late replies; after an ambiguous failure the UI retains its last confirmed value, reads current status, and reports that the write was not confirmed. No power-control operation is routed through HTTP, MQTT, the window-control bridge, or a user-session assertion.

## Network publication

HTTP routing is read-only and testable independently from NIO. Only `/health`, `/v1/accounts`, and `/v1/sensors` accept `GET`; the peer address must match an explicit local IPv4 CIDR. HTTP and MQTT are disabled by default.

MQTT uses retained availability and account state, Home Assistant Discovery, a last will, reconnect attempts, and a subscription to `homeassistant/status` for Discovery replay. A durable ledger records only successfully advertised topics; every publication reconciles it with the current account/field selection, so removals and deselections remain pending across broker outages and daemon restarts until their retained tombstones succeed. TLS uses MQTTNIO's client configuration with full certificate and hostname verification.

Public models contain stable account ID, provider, user label, source, provider observation time, freshness, last collection attempt/failure, and only the supported quota or balance fields. Optional means unknown or unavailable; it is not encoded as zero.

Window MQTT Discovery has its own durable ledger, independent from the sensor ledger. `window-control.json` stores a generated installation UUID and the default-off remote preference. Current GUI snapshots carry a topology/session generation; root routing adds a separate epoch for opt-in, broker, and connection changes. Heartbeats have a five-second lease. A command must match both epochs and a current display UUID; operation/result models contain no window identity or content. The app retains the actual AX object locally for the operation.

An independent one-second control-publication loop keeps GUI availability and Discovery responsive even during slow provider collection. MQTT uses clean sessions and never retains commands/results. Unavailable GUI sessions keep known display descriptors offline, while explicit display removal and opt-out reconcile Discovery tombstones. The native controller owns a 20-second deadline; GUI/root reply guards add transport margins, not retries.

## Notification engine

`NotificationEngine` is a root-owned actor with a versioned private store. It validates and rate-limits new events before copying state, evaluates global or exact source rules, persists the candidate state before returning delivery effects, and keeps delivery attempts separate per channel. Duplicate event UUIDs are no-ops; optional deduplication keys update the newest matching source record. Ordinary inactive records expire after 30 days, active critical records survive retention pruning, and the store is capped at 5,000 records/sources.

The MQTT ingress and acknowledgement subscriptions use clean sessions and reject retained messages. Events and panel text are QoS 1 non-retained publications. Active critical records and notification availability are retained; clearing state emits retained empty tombstones. Notification content is absent from sensor/Discovery models and logs, but selected notification topics deliberately contain title/message.

The logged-in app registers as the one trusted reverse-XPC notification agent during its existing heartbeat. Root queues failed Mac deliveries and drains them when a valid agent returns; after logout the root service does not attempt to access a user Keychain or bypass TCC. Notification Center delivery uses a stable event UUID request identifier, and only critical notifications expose the fixed acknowledgement action.

Panel text is an MQTT handoff consumed by the Home Assistant blueprint. Direct wake and sound use a separately paired NSPanel local-HTTP client. Pairing is two-step, and the returned token is saved only after a successful private atomic write. Each request re-resolves the configured host, requires every IPv4 result to be local, selects a deterministic numeric address, refuses redirects, and bounds time and response size. Wake retries once only for transport/timeout; sound is durably marked attempted before its at-most-once call.

AI detection compares the previous and current stored snapshots after collection. It emits only configured transitions: authorization loss/recovery, quota threshold crossings, fresh observed quota resets, exact decimal balance crossings, and consecutive-failure boundary/recovery. Detection failure does not block snapshot persistence or sensor publication.

## Installation and lifecycle

`make install` is the only install path. It stages the app, installs root-owned helper binaries and the LaunchDaemon plist, pins the selected Codex binary, records trust hashes, and bootstraps launchd. Ordinary builds make no system changes. Changes to the app/daemon XPC contract require reinstalling both trusted hashes. `make uninstall` stops the service, releases process-owned assertions, and removes installed code while preserving `/Library/Application Support/MacTower`, including the saved sleep mode; `make purge-data` handles destructive data removal separately.

Automated tests cover parsers, missing fields, exact money strings, snapshot freshness, secret-free public JSON, local ACLs, HTTP method rejection, MQTT plans/tombstones, notification policy/history/rate limits, retained ingress rejection, panel client safety, reverse-XPC delivery, Home Assistant blueprint structure, storage isolation, Claude bridge restoration, XPC DTO trust requirements, power transitions through an injected backend, release-before-network ordering, CLI privilege behavior, and install/uninstall/purge dry-runs. The optional Docker test verifies sensor, window, and notification retained/non-retained wire behavior through Mosquitto. Native IOKit behavior, real OAuth, signing/launchd integration, logout operation, Notification Center, Home Assistant mobile delivery, NSPanel pairing, and production broker ACLs remain manual acceptance checks.
