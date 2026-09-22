# Security

## Trust boundary

MacTower deliberately provides no application-level authentication on its HTTP sensor endpoints. Enabling HTTP authorizes every client in the configured IPv4 allowlist to read the published telemetry. Never bind it to a public, VPN-wide, or otherwise untrusted network. MQTT security is provided by the configured local broker; use broker credentials and certificate-verified TLS where appropriate.

There are no HTTP or MQTT management operations. Login, secrets, configuration, and account removal are available only through the local XPC management contract.

## Privileged installation

The GUI runs as the installation owner's UID. The LaunchDaemon runs as root. Local OSS builds use ad-hoc hardened-runtime signatures, so the installer records exact app and daemon cdhash values in a root-owned, non-writable trust manifest:

- the daemon accepts XPC clients only when both the effective UID and app cdhash match;
- the app accepts the daemon only when its cdhash matches;
- management operations are a finite Codable enum and never accept commands or executable paths.

An ad-hoc hash is installation pinning, not a public identity or notarization. Rebuilding changes it; reinstall to update both trusted hashes. The project does not claim protection if an attacker already has root access.

Installed executables are root-owned. The daemon starts only `/Library/PrivilegedHelperTools/mac-tower-codex`; it does not resolve Codex from a user-controlled `PATH`.

## Credentials and files

Daemon-owned account data is stored below `/Library/Application Support/MacTower`: directories are forced to mode `0700`, files to `0600`, writes use a temporary exclusive file followed by an atomic rename, and reads/writes refuse symbolic links. Codex accounts use separate `CODEX_HOME` directories and file-backed credential stores managed by the official client. DeepSeek and MQTT secrets are stored separately from public configuration.

Claude credentials are neither read nor copied. The user-session app installs a statusline wrapper only into the explicitly supplied `CLAUDE_CONFIG_DIR`. It saves the prior statusline object and command, forwards the prior command's output, and offers an explicit restore action. The root daemon reads the resulting bounded regular snapshot with `O_NOFOLLOW` and verifies its account ID and provider.

Provider credentials, provider email addresses, raw responses, project paths, transcripts, and conversation content are not emitted through HTTP/MQTT or normal logs. Account labels are user-controlled and are public once network publishing is enabled, so do not use a sensitive label.

`make uninstall` preserves account data. `make purge-data` is a distinct destructive action requiring an exact confirmation.

## Known limitations

- Local development builds are not Developer ID signed or notarized.
- IPv6 publishing is not implemented.
- An allowlisted network is a trust grant; RFC1918 addressing alone does not make its devices trustworthy.
- Network listener changes require a daemon restart.
- Claude telemetry is last-seen statusline data, not an autonomous provider poll. It can become stale after the CLI or user session stops.
- Unit fixtures and installer dry-runs do not replace manual testing with real accounts, an installed LaunchDaemon, logout, or a real MQTT broker.

## Reporting a vulnerability

Do not include credentials, personal data, or an unredacted exploit against a running installation in a public issue. Use the repository's private vulnerability reporting feature if available. Otherwise, open a public issue requesting a private channel without disclosing sensitive details.

There is currently no published security-support window or response-time commitment.
