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
| `make test-mqtt-docker` | Start a disposable loopback-only Mosquitto 2.x container and test telemetry, window-command delivery, retained-message rejection, and reconnection. |
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

`make check` uses anonymized fixtures, injected window and power backends, command-routing/bridge tests, and local lifecycle dry-runs. It does not install the daemon or create a real power assertion. `make test-mqtt-docker` separately exercises a real local broker. Neither proves live OAuth, real-account quota responses, installed XPC signature enforcement, LaunchDaemon operation after logout, native window behavior, or native sleep behavior.

Before deployment, manually check an installed build with two or more displays: ordinary/fullscreen Safari, Terminal and an Electron app; mixed scaling/vertical layout; unplugging a destination; lock/unlock and locking during fullscreen transition; fast user switching; login-item registration; Accessibility revocation; and an ad-hoc upgrade. Separately verify all three sleep modes, an already-off display, AC/battery transitions, manual sleep/wake, lock/logout, daemon restart, return to Normal, and assertion cleanup. Live GUI/AX, IOKit, signed XPC and login/logout acceptance remain separate from mocked and broker tests.

## License

MIT. See [LICENSE](LICENSE).
