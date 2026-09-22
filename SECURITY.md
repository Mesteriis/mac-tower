# Security

## Trust boundary

MacTower deliberately provides no application-level authentication on its HTTP sensor endpoints. Enabling HTTP authorizes every client in the configured IPv4 allowlist to read the published telemetry. Never bind it to a public, VPN-wide, or otherwise untrusted network. MQTT security is provided by the configured local broker; use broker credentials and certificate-verified TLS where appropriate.

HTTP has no management operations. Login, secrets, configuration, and account removal remain available only through the local XPC management contract. MQTT has three explicitly opted-in state-changing surfaces: window movement, notification inbox ingestion, and notification acknowledgement. All are off by default. Ingestion creates private history and may fan text out to configured channels. Acknowledgement deactivates an active critical event, stops its reminders, removes its Mac notification, and clears its retained active topic.

The broker is the authority for these MQTT senders. Use distinct credentials and restrict publishers to the exact topics they need: trusted event producers to `<prefix>/notifications/inbox/<source>`, Home Assistant to `<prefix>/notifications/ack`, and trusted Home Assistant clients to the current window command topics. MacTower's credential needs subscribe access to inbox/ack and publish access to notification events, panel, active, availability, sensor state, and Discovery. An anonymous or overly broad broker ACL defeats these boundaries.

## Window-control boundary

The root daemon never performs Accessibility operations. A persistent, mutually cdhash-pinned XPC connection registers a user-session controller belonging to the installation owner's UID. There may be only one live registered controller; heartbeat leases expire after five seconds. GUI exit/disconnection and invalid session state revoke routing. The app still requires the user's separate Accessibility consent; root does not bypass TCC.

The MQTT broker is the authority for network window commands. Restrict publisher ACLs on `<prefix>/window-control/+/+/move` to trusted Home Assistant clients. The opt-in switch does not authenticate an MQTT sender; an anonymous or overly permissive broker grants other clients the same desktop-control capability. Use broker credentials and certificate-verified TLS on untrusted shared links. There is no new unauthenticated HTTP command API or shell-command interface.

Commands use QoS 0, clean MQTT sessions with zero session expiry, subscription retain handling `doNotSend`, and retained-flag rejection. Epoch-qualified topics prevent old commands targeting a later session. The epoch is not a secret or authentication token. It is also checked across XPC, alongside the GUI's topology/session generation. Offline commands are discarded rather than queued. Duplicate GUI request IDs and overlapping operations are rejected.

Each AX-changing stage rechecks permission, active owner/console session, deadline, target topology, and cancellation. The lock adapter accepts only a real boolean `false` from the internal `IOConsoleLocked` registry property. Missing, mistyped, or unknown state fails closed. This is a compatibility dependency, not a documented lock-state API or an atomic guarantee against a lock transition racing an AX request. No restoration steps are deliberately performed after detected lock/cancellation.

Window titles, application names/lists, paths, and window contents are not part of public command/result models or logs. Display names are published by Discovery. The finite command cannot specify a process, executable, shell string, arbitrary AX attribute, or arbitrary coordinates.

## Notification boundary

Notification ingress and acknowledgements require separate saved opt-ins. Both use clean MQTT sessions with no offline queue and reject every retained delivery before decoding. Topics are bounded to 512 bytes; payloads are bounded to 16 KiB. Source IDs are a single validated segment, titles are at most 160 Unicode scalars, messages 2,000, and deduplication keys 128 without control characters. New input is limited to 30 events per source and 300 total per rolling minute. Invalid, expired, inconsistent, or more-than-five-minutes-future timestamps are rejected. Persistent state is capped at 5,000 records and 5,000 known sources.

Acknowledgement contains only a schema version and event UUID. It cannot create an event or run an arbitrary operation, but it does change durable notification state and suppress future reminders for that active critical event. Event UUID replay is idempotent. MQTT `handed_off` means broker publication succeeded, not that Home Assistant, a panel, or a person displayed or read the message.

Notification title and message are deliberately published only on selected notification routes: non-retained `<prefix>/notifications/events`, non-retained `<prefix>/notifications/panel`, and retained `<prefix>/notifications/active/<event-uuid>`. Active critical text therefore persists at the broker until acknowledgement or expiry publishes a tombstone. Notification text is not added to sensor state, Home Assistant Discovery configuration, public HTTP sensor responses, or ordinary logs. The private root notification store also contains event text and uses the same `0700` directory, `0600` regular-file, no-symlink, atomic-write boundary as other daemon state.

Mac Notification Center delivery crosses the pinned reverse XPC connection to the installation owner's current GUI session. Logout makes that channel unavailable; it does not cause root to impersonate the user or bypass notification consent. Critical action buttons can invoke only the fixed acknowledgement operation. Removing a notification after acknowledgement is best-effort UI cleanup, not evidence that it had been read.

NSPanel wake and sound use its local Open API over plain HTTP, authenticated by a daemon-held token. Pairing requires an explicit local host and physical approval on the panel; redirects, public/mixed DNS results, oversized responses, and malformed replies are rejected. Plain HTTP cannot protect the token against an observer on the same network, so use a trusted, isolated IoT LAN. Clearing the token disables direct operations until a new physical pairing; it does not revoke a token at the panel itself.

## Power-control boundary

Sleep-mode mutation is available only through the authenticated local XPC management contract. It adds no HTTP route, MQTT command, shell command, or other LAN mutation. The finite request selects only `normal`, `keep_mac_awake`, or `keep_mac_and_displays_awake`; callers cannot provide an assertion type, assertion name, duration, or arbitrary IOKit value.

The root daemon is the sole power-assertion owner. Its IOKit assertion names are fixed strings containing no account, user, host, or other user-controlled data. Public status and normal logs expose only finite issue codes; raw IOKit return values and handles do not cross XPC or enter LAN telemetry. Shutdown attempts to release MacTower assertions before stopping network services. The OS also scopes assertions to the daemon process; MacTower never enumerates or removes assertions owned by other processes.

The selected mode is stored in the existing private root data directory. Uninstalling stops the owner and releases its live assertion while preserving the saved selection; purging data remains a separate explicit action. Reinstalling or restarting can therefore restore a saved non-normal mode.

## Privileged installation

The GUI runs as the installation owner's UID. The LaunchDaemon runs as root. Local OSS builds use ad-hoc hardened-runtime signatures, so the installer records exact app and daemon cdhash values in a root-owned, non-writable trust manifest:

- the daemon accepts XPC clients only when both the effective UID and app cdhash match;
- the app accepts the daemon only when its cdhash matches;
- account management operations use a finite Codable enum; window callbacks also have a fixed contract. Neither accepts shell commands or executable paths.

An ad-hoc hash is installation pinning, not a public identity or notarization. Rebuilding changes it; reinstall to update both trusted hashes. The project does not claim protection if an attacker already has root access.

Installed executables are root-owned. The daemon starts only `/Library/PrivilegedHelperTools/mac-tower-codex`; it does not resolve Codex from a user-controlled `PATH`.

## Credentials and files

Daemon-owned account data is stored below `/Library/Application Support/MacTower`: directories are forced to mode `0700`, files to `0600`, writes use a temporary exclusive file followed by an atomic rename, and reads/writes refuse symbolic links. Codex accounts use separate `CODEX_HOME` directories and file-backed credential stores managed by the official client. DeepSeek and MQTT secrets are stored separately from public configuration.

Claude credentials are neither read nor copied. The user-session app installs a statusline wrapper only into the explicitly supplied `CLAUDE_CONFIG_DIR`. It saves the prior statusline object and command, forwards the prior command's output, and offers an explicit restore action. The root daemon reads the resulting bounded regular snapshot with `O_NOFOLLOW` and verifies its account ID and provider.

Provider credentials, provider email addresses, raw responses, project paths, transcripts, and conversation content are not emitted through HTTP/MQTT or normal logs. Account labels are user-controlled and are public once network publishing is enabled, so do not use a sensitive label.

`make uninstall` preserves account data. `make purge-data` is a distinct destructive action requiring an exact confirmation.

## Known limitations

- Local development builds are not Developer ID signed or notarized.
- Native fullscreen uses capability-checked `AXFullScreen`, which is not uniformly supported. Split View pairs and arbitrary Spaces are not managed. A partially completed operation is not rolled back automatically.
- Accessibility grants and Service Management login-item approval are controlled by macOS. An ad-hoc update may require reapproval and always requires updating the trusted installation hashes.
- Lock detection, native AX operation and live signed duplex XPC require manual acceptance on supported macOS versions. Synthetic backends do not prove those integrations.
- IPv6 publishing is not implemented.
- An allowlisted network is a trust grant; RFC1918 addressing alone does not make its devices trustworthy.
- Network listener changes require a daemon restart.
- Notification MQTT ingress and acknowledgement trust the broker identity/ACL configuration; MacTower does not add per-message signatures.
- Active critical notification text is intentionally retained on the configured broker until a tombstone is published.
- NSPanel direct control is plain HTTP on the local network; it is not suitable for an untrusted shared LAN.
- Mac Notification Center requires the user-session app and permission. A successful handoff is not proof of display or reading.
- Keep-awake modes prevent idle sleep only. They do not override manual sleep, lid-close sleep, critical-battery protection, screen locking, or Dark Wake, and they do not wake an already-off display.
- Unit tests inject a fake assertion backend. Native IOKit assertion creation, release, restoration after daemon restart/logout, and battery behavior require manual acceptance.
- Claude telemetry is last-seen statusline data, not an autonomous provider poll. It can become stale after the CLI or user session stops.
- Unit fixtures, blueprint validation, broker tests, and installer dry-runs do not replace manual testing with real accounts, an installed LaunchDaemon, logout, Notification Center, Home Assistant, or an NSPanel Pro.

## Reporting a vulnerability

Do not include credentials, personal data, or an unredacted exploit against a running installation in a public issue. Use the repository's private vulnerability reporting feature if available. Otherwise, open a public issue requesting a private channel without disclosing sensitive details.

There is currently no published security-support window or response-time commitment.
