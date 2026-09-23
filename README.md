# MacTower

MacTower is an open-source macOS 14+ menu bar app and root background service that publishes selected local AI-account telemetry over read-only HTTP and MQTT. It can also move the active window between displays, locally or through explicitly enabled Home Assistant MQTT buttons.

The first sensor release supports Codex, Claude Code, and DeepSeek. Cursor appears in settings as **Soon** and has no importer, authorization access, or network activity.

## What it collects

- **Codex:** isolated multi-account OAuth sessions through the official Codex app-server, including every returned rate-limit bucket, reset times, plan, and reset-credit metadata.
- **Claude Code 2.1.251+:** the latest rate-limit fields delivered to a user profile's statusline. MacTower preserves the previous statusline command and output, and can restore it. It does not send artificial model requests.
- **DeepSeek:** API availability plus exact total, granted, and topped-up balances by currency from `GET /user/balance`. DeepSeek does not expose quota percentages or reset dates through this endpoint, so MacTower does not invent them.

Provider credentials, email addresses, and raw provider responses are never included in HTTP, MQTT, or normal logs. Missing data remains missing rather than becoming zero.

Provider contracts: [Codex app-server](https://learn.chatgpt.com/docs/app-server), [Claude statusline rate limits](https://code.claude.com/docs/en/statusline#rate-limit-usage), and [DeepSeek balance API](https://api-docs.deepseek.com/zh-cn/api/get-user-balance/).

## Requirements

- macOS 14 or later.
- Swift 6.0 or later through Xcode or Command Line Tools.
- `make` and `xcrun swift-format`.
- The official `codex` executable on `PATH` when running `make install`.
- Claude Code 2.1.251+ for Claude rate-limit statusline fields.

## Development

```sh
make build
make test
make app
make run
make check
```

`make app` creates `dist/MacTower.app` with a local ad-hoc hardened-runtime signature. It does not install or start the privileged service.

| Command | Purpose |
| --- | --- |
| `make build` | Build all Swift targets. |
| `make test` | Run Swift and CLI regression tests. |
| `make test-homeassistant-blueprint` | Validate the Home Assistant notification blueprint and its acknowledgement safety rules. |
| `make test-mqtt-docker` | Start a disposable loopback-only Mosquitto 2.x container and test telemetry, window commands, notification ingress/outbound/ack topics, retained-message rejection, and reconnection. |
| `make check` | Build, test, lint, and validate resources and shell scripts. |
| `make format` / `make lint` | Format or verify Swift sources. |
| `make app` / `make run` | Package or run the development menu bar app. |
| `make release` | Build optimized binaries and the app bundle. |
| `make install-dry-run` | Print installation actions without changing the Mac. |
| `make install` | Build and install the app, verified OpenAI-signed Codex copy, helper tools, and LaunchDaemon; prompts for administrator access. |
| `make uninstall` | Remove installed code and the LaunchDaemon while preserving account data. |
| `make purge-data` | Separately and permanently remove preserved account data after typing an exact confirmation. |

Development bundles are not Developer ID signed or notarized. Every local OSS install records the ad-hoc cdhash of the app and daemon; rebuilding changes the hash, so upgrades require `make install` again.

## Configure accounts

After `make install`, open MacTower Settings → Accounts.

- **Codex:** choose a stable account ID and name, then start OAuth. OAuth flows are serialized, can be cancelled from settings, and expire after ten minutes. Each account has its own daemon-owned `CODEX_HOME`; the installed Codex client owns and refreshes its credentials. Existing application refresh tokens are not copied. Removing the account deletes that isolated credential directory.
- **Claude:** supply the profile's explicit `CLAUDE_CONFIG_DIR` and snapshot path ending in `<account-id>.json`. The app installs a reversible wrapper around that profile's current `statusLine`. Multiple accounts require separate Claude config directories. Values update only when that Claude CLI profile runs its statusline.
- **DeepSeek:** enter the API key. Replacing the key is an explicit repeat of this action; no automatic API-key rotation exists.

The app never silently scans the disk for profiles.

## Publish to the LAN

Publishing is off by default. Settings → Publishing selects either every connected account or an explicit account set, plus individual quota/balance fields. The same selection applies to HTTP and MQTT. Configuration is written through authenticated XPC; listener changes take effect after the daemon restarts.

HTTP exposes only:

- `GET /health`
- `GET /v1/accounts`
- `GET /v1/sensors`

Other methods and unknown routes are rejected. HTTP is IPv4-only and requires an explicit RFC1918, loopback, or link-local allowlist containing the selected bind address.

MQTT accepts a private IPv4 address, `localhost`, a single-label LAN hostname, or a `.local` hostname. It supports broker username/password, certificate-verified TLS, retained account state, availability, Home Assistant Discovery, reconnects, HA birth republishing, and durable retained-topic reconciliation. Removed accounts and deselected fields are tombstoned after the broker reconnects; the advertised-topic ledger advances only after successful publication.

## Deliver notifications

Settings → Notifications configures a separate notification engine. It is off by default. Enabling MQTT sensor publication does not enable notification ingress, acknowledgements, or any delivery route; each must be selected explicitly.

With MQTT prefix `<prefix>`, the notification contract is:

| Topic | Direction | Retained | Purpose |
| --- | --- | --- | --- |
| `<prefix>/notifications/inbox/<source>` | client → MacTower | rejected if retained | Submit one event. `<source>` is one validated segment. |
| `<prefix>/notifications/events` | MacTower → broker | no | Events routed to the MQTT channel. |
| `<prefix>/notifications/panel` | MacTower → Home Assistant | no | Events routed to the panel text channel. |
| `<prefix>/notifications/active/<event-uuid>` | MacTower → broker | yes | Current active critical state; acknowledgement/expiry publishes a retained tombstone. |
| `<prefix>/notifications/ack` | Home Assistant → MacTower | rejected if retained | Acknowledge one active critical event. |
| `<prefix>/notifications/availability` | MacTower → broker | yes | Notification publisher availability. |

An illustrative non-retained inbox payload is:

```json
{
  "schema_version": 1,
  "event_id": "550e8400-e29b-41d4-a716-446655440000",
  "severity": "critical",
  "title": "UPS on battery",
  "message": "Runtime is below ten minutes",
  "created_at": "2026-09-22T18:00:00Z",
  "expires_at": "2026-09-22T19:00:00Z",
  "dedup_key": "ups-on-battery"
}
```

The acknowledgement payload is `{"schema_version":1,"event_id":"<event-uuid>"}`. Event identifiers are idempotent. Acknowledgement is accepted only for an active critical event; it stops reminders and clears retained active state. `handed_off` means only that the selected adapter accepted the delivery. It does not mean a person saw or read it.

Use separate broker identities and least-privilege ACLs. Source publishers need write-only access to their exact inbox topics. Home Assistant needs read access to the panel topic and, only when acknowledgement is enabled, write access to the exact ack topic. MacTower needs subscribe access to inbox/ack and publish access to events, panel, active, availability, and its Discovery topics. Do not grant arbitrary LAN clients write access to inbox or ack.

### Home Assistant and NSPanel Pro

Import [`homeassistant/blueprints/automation/mactower/notifications.yaml`](homeassistant/blueprints/automation/mactower/notifications.yaml), create an automation from it, set the panel topic and ack topic above, and explicitly select the NSPanel companion application's `notify.mobile_app_*` action. The blueprint forwards text, uses the event UUID as a stable tag, adds Acknowledge only for eligible critical events, and sends a QoS 1 non-retained acknowledgement. MacTower does not guess a mobile-app notify target.

Panel text travels through MQTT and Home Assistant. Wake and sound use the NSPanel Pro local Open API directly over plain HTTP. Configure an explicit local IPv4 address or `.local` name; the default port is `8081`. Put the Mac and panel on a trusted IoT network because the local token and commands are not protected by TLS on this link. DNS is re-resolved for each operation and every resolved address must remain local.

Pairing is intentionally two-call and physical: press **Pair**, approve MacTower on the panel and press **Done**, then press **Pair** again to receive and store the token. **Clear token** removes only MacTower's saved token; pair again before using direct wake or sound. Supported sound names are `alert1`–`alert5`, `doorbell1`–`doorbell5`, and `alarm1`–`alarm5`. Sound volume is 0–100 and countdown is 0–1799 seconds. The test buttons independently exercise Mac Notification Center, panel text, panel wake, and the default panel sound.

macOS Notification Center permission is requested only from Settings. If denied, use the provided System Settings link. The user-session app must be running for Mac notifications; after logout, root-owned MQTT delivery, retained active state, reminders, and direct paired-panel operations can continue, while the Mac channel stays unavailable. Notification Center action buttons acknowledge critical events only.

Global rules and per-source overrides choose channels separately for `info`, `warning`, and `critical`, with cooldown, critical reminders, optional panel wake/sound, and daily local-time quiet hours. Critical bypass is explicit. History is private daemon state; the UI loads at most 100 rows per page and filters only loaded pages. Ordinary history is retained for 30 days, while old active critical records are preserved until resolved; storage is bounded to 5,000 records.

AI rules can notify on authorization loss/restoration, a remaining-quota threshold crossed from above, a quota reset confirmed by newer provider telemetry, exact DeepSeek currency-balance thresholds, and a configured consecutive-failure boundary/recovery. Missing values do not trigger, repeated Claude statusline data is not a fresh observation, and the passage of a reset timestamp alone does not invent a reset. MacTower does not yet produce battery notifications or battery sensors.

## Move the active window

Open Settings → Windows and grant **Accessibility** to the installed MacTower app in macOS System Settings. Permission requests happen only when you press the local permission button. No Screen Recording permission is requested. The menu's **Move active window to** submenu lists connected logical displays. It captures the external focused window when the menu opens; opening MacTower's settings does not select some unrelated previous window.

An ordinary, resizable window is fitted to the destination's working area, excluding the Dock and menu bar. Native fullscreen windows first leave fullscreen, move, then attempt to restore fullscreen. The operation reads back the result and can report partial success if an application restricts its frame or fullscreen restoration fails. There is one operation at a time, no queue or automatic retry, and a 20-second native deadline. The GUI/daemon allow a small additional reply timeout; a timeout does not prove that no window change occurred.

Limitations: standard AX windows only; minimized windows, dialogs, ambiguous fullscreen states and Split View pairs are not supported. MacTower does not move arbitrary Spaces, use private Spaces APIs, or simulate keyboard/mouse input. Fullscreen capability varies by application. Display UUIDs, not list positions, select destinations; mirrored displays form one logical target. Disconnecting a target or changing the physical layout during an operation cancels remaining steps. Dock/menu working-area changes are refreshed between stages without invalidating physical topology.

For Home Assistant, configure MQTT and separately enable **Allow Home Assistant to move windows** in Settings → Windows. This switch takes effect immediately, without restarting the daemon. Buttons have stable identities per installation/display. Grant write access to command topics only to trusted broker users, normally Home Assistant; publishing there grants control over your desktop. HTTP remains read-only.

- Command topic: `<prefix>/window-control/<current-epoch>/<display-uuid>/move`, exact payload `PRESS`, QoS 0, non-retained. Use the Discovery button rather than hard-coding its changing epoch.
- Result topic: `<prefix>/window-control/result`, non-retained JSON containing `requestID`, `displayID`, and `code`. It contains no window title, application list, or content.
- Availability: both `<prefix>/availability` and `<prefix>/window-control/availability` must be `online`.

Control requires the app running in the installation owner's active, unlocked console session. A five-second heartbeat lease, connection invalidation and per-stage session checks disable stale control. Reconnection, lock/session changes and opt-in changes invalidate old command epochs; retained commands are rejected. Commands are never held for the next login/unlock. AI telemetry continues while window control is unavailable. Removed displays/disabled control clean up their own retained Discovery records without removing AI sensors.

Settings → Windows offers **Open MacTower at login** through macOS Service Management. This is an explicit user preference, separate from the root daemon. An ad-hoc rebuild can require granting Accessibility again; reinstall to refresh trusted XPC hashes. On an uninstalled development bundle, local menu control can work after permission is granted, but daemon-backed controls remain unavailable.

The lock gate requires an explicit boolean `false` from `IOConsoleLocked` together with matching console-session identity. This registry key is an internal macOS compatibility interface, not a stable public API: missing or unrecognized state disables control. Check lock/unlock on each supported macOS version; there is no atomic transaction between checking the session and sending an AX message.

## Control idle sleep

The menu's **Sleep mode** submenu and Settings → General offer the same persistent three-position control:

- **Normal** holds no MacTower power assertion.
- **Keep Mac awake** lets displays turn off normally but prevents idle system sleep.
- **Keep Mac and displays awake** prevents idle display sleep as well as the resulting idle system sleep.

The root daemon owns the assertion, so the selected non-normal mode continues after the menu app quits and after logout. The saved choice is restored when the daemon starts. `make uninstall` removes the daemon and therefore releases its live assertion, but preserves the saved choice with the other MacTower data; reinstalling restores it. Return to **Normal** before uninstalling if you do not want a later reinstall to restore a keep-awake mode.

Non-normal modes use more energy, especially on battery. They prevent only idle sleep: MacTower does not defeat manual sleep, lid-close sleep, critical-battery protection, screen locking, or Dark Wake behavior. Selecting the display-awake mode does not wake a display that is already off. Assertion failures are shown as requested/saved/applied mismatches instead of being reported as success.

Sleep-mode changes use the authenticated local XPC contract and are never exposed through HTTP or MQTT. Rebuilding either side of that installed contract changes its pinned hash; run `make install` again before testing a new build.

## Runtime and data

The GUI runs in the logged-in user session. The LaunchDaemon runs as root so Codex, DeepSeek, HTTP, and MQTT continue after logout. Claude remains user-session dependent because its official CLI produces statusline telemetry.

Root data lives in `/Library/Application Support/MacTower` with private directory and file modes. The daemon uses a pinned Codex executable from `/Library/PrivilegedHelperTools`, not the runtime user's `PATH`. The app and daemon authenticate each other over a finite XPC contract using installation-owner UID and exact cdhash requirements.

See [architecture](docs/architecture.md), [security](SECURITY.md), and [contributing](CONTRIBUTING.md).

## Validation scope

`make check` uses anonymized fixtures, injected window and power backends, command-routing/bridge tests, Home Assistant blueprint validation, and local lifecycle dry-runs. It does not install the daemon or create a real power assertion. `make test-mqtt-docker` separately exercises a disposable real broker, including notification retained/non-retained wire behavior. Neither proves live OAuth, real-account quota responses, installed XPC signature enforcement, LaunchDaemon operation after logout, native window behavior, native sleep behavior, Notification Center presentation, or a real NSPanel/Home Assistant delivery.

Before deployment, run `make install` again after every app/daemon rebuild so the pinned XPC hashes match. Manually check an installed build with two or more displays: ordinary/fullscreen Safari, Terminal and an Electron app; mixed scaling/vertical layout; unplugging a destination; lock/unlock and locking during fullscreen transition; fast user switching; login-item registration; Accessibility revocation; and an ad-hoc upgrade. Separately verify all three sleep modes, an already-off display, AC/battery transitions, manual sleep/wake, lock/logout, daemon restart, return to Normal, and assertion cleanup.

**Manual notification acceptance status: NOT RUN.** It covers Notification Center allow/deny, duplicate and expired MQTT input, source/global rules, quiet hours, Mac acknowledgement, panel text, paired wake, every sound selected for use, Home Assistant acknowledgement, broker/HA/panel outages, logout/login, daemon restart, and absence of tokens or notification text in ordinary logs and LAN sensor endpoints. These checks are not PASS until performed on the installed Mac and real Home Assistant/NSPanel systems.

## License

MIT. See [LICENSE](LICENSE).
