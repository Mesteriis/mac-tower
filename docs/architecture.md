# Architecture

## Components

| Component | Context | Responsibility |
| --- | --- | --- |
| `MacTowerApp` | Logged-in user | Menu/settings, login-item preference, provider setup, and short-lived management plus persistent duplex window XPC connections. |
| `MacTowerCore` | Shared | Public sensor model, provider parsers/clients, storage boundaries, HTTP routing, MQTT planning, management DTOs, and validation. |
| `MacTowerTransport` | Root daemon | SwiftNIO HTTP server and MQTTNIO publisher. |
| `MacTowerWindowControl` | Logged-in user | Display topology, session eligibility, bounded Accessibility adapter and a single app-lifetime window controller. |
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

Home Assistant button ─> MQTT command router ─> pinned duplex XPC ─> user WindowController ─> AX window
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

## Network publication

HTTP routing is read-only and testable independently from NIO. Only `/health`, `/v1/accounts`, and `/v1/sensors` accept `GET`; the peer address must match an explicit local IPv4 CIDR. HTTP and MQTT are disabled by default.

MQTT uses retained availability and account state, Home Assistant Discovery, a last will, reconnect attempts, and a subscription to `homeassistant/status` for Discovery replay. A durable ledger records only successfully advertised topics; every publication reconciles it with the current account/field selection, so removals and deselections remain pending across broker outages and daemon restarts until their retained tombstones succeed. TLS uses MQTTNIO's client configuration with full certificate and hostname verification.

Public models contain stable account ID, provider, user label, source, provider observation time, freshness, last collection attempt/failure, and only the supported quota or balance fields. Optional means unknown or unavailable; it is not encoded as zero.

Window MQTT Discovery has its own durable ledger, independent from the sensor ledger. `window-control.json` stores a generated installation UUID and the default-off remote preference. Current GUI snapshots carry a topology/session generation; root routing adds a separate epoch for opt-in, broker, and connection changes. Heartbeats have a five-second lease. A command must match both epochs and a current display UUID; operation/result models contain no window identity or content. The app retains the actual AX object locally for the operation.

An independent one-second control-publication loop keeps GUI availability and Discovery responsive even during slow provider collection. MQTT uses clean sessions and never retains commands/results. Unavailable GUI sessions keep known display descriptors offline, while explicit display removal and opt-out reconcile Discovery tombstones. The native controller owns a 20-second deadline; GUI/root reply guards add transport margins, not retries.

## Installation and lifecycle

`make install` is the only install path. It stages the app, installs root-owned helper binaries and the LaunchDaemon plist, pins the selected Codex binary, records trust hashes, and bootstraps launchd. Ordinary builds make no system changes. `make uninstall` stops the service and removes installed code while preserving `/Library/Application Support/MacTower`; `make purge-data` handles destructive data removal separately.

Automated tests cover parsers, missing fields, exact money strings, snapshot freshness, secret-free public JSON, local ACLs, HTTP method rejection, MQTT plans/tombstones, storage isolation, Claude bridge restoration, XPC DTO trust requirements, CLI privilege behavior, and install/uninstall/purge dry-runs. The optional Docker test verifies a retained MQTTNIO round trip through Mosquitto. Real OAuth, signing/launchd integration, logout operation, and production broker configuration remain manual acceptance checks.
