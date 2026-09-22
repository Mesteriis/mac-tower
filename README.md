# MacTower

MacTower is an open-source macOS 14+ menu bar app and root background service that publishes selected local AI-account telemetry to Home Assistant over read-only HTTP and MQTT.

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
| `make test-mqtt-docker` | Start a disposable Mosquitto 2.x container and verify a retained MQTTNIO round trip. |
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

## Runtime and data

The GUI runs in the logged-in user session. The LaunchDaemon runs as root so Codex, DeepSeek, HTTP, and MQTT continue after logout. Claude remains user-session dependent because its official CLI produces statusline telemetry.

Root data lives in `/Library/Application Support/MacTower` with private directory and file modes. The daemon uses a pinned Codex executable from `/Library/PrivilegedHelperTools`, not the runtime user's `PATH`. The app and daemon authenticate each other over a finite XPC contract using installation-owner UID and exact cdhash requirements.

See [architecture](docs/architecture.md), [security](SECURITY.md), and [contributing](CONTRIBUTING.md).

## Validation scope

`make check` uses anonymized fixtures and local lifecycle dry-runs. `make test-mqtt-docker` separately exercises a real local broker. Neither proves live OAuth, real-account quota responses, LaunchDaemon operation after logout, or notarized distribution; those require explicit manual testing on an installed system.

## License

MIT. See [LICENSE](LICENSE).
