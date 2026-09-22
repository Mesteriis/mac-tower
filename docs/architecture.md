# Architecture

## Components

| Component | Context | Current responsibility |
| --- | --- | --- |
| `MacTowerApp` | Logged-in user | SwiftUI `MenuBarExtra`, settings, and the menu bar title preference. |
| `MacTowerCore` | Shared library | Daemon command-line parsing, testable without a UI or root. |
| `MacTowerDaemon` | Root service | Command-line help/version, privilege check, and termination-signal lifecycle. |

The package uses explicit source paths under `src/` and test paths under `tests/`. Helper scripts live in `src/scripts/`; application bundle resources live in `src/Resources/`.

The application and daemon are separate executables. There is currently no communication channel between them. The application shows scaffold status, not a live daemon connection or collected machine metrics.

## Process and permission boundaries

The menu bar application runs as the logged-in user because its UI and future window-management operations belong to that user's graphical session. Root execution is confined to the separate daemon. A daemon's root privileges do not provide access to the logged-in user's WindowServer session or satisfy Accessibility consent. See Apple's [daemon design guidance](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/DesigningDaemons.html).

Daemon invocation with `--help` or `--version` is nonprivileged. Starting its service loop requires effective user ID 0. The current loop remains idle until it receives a termination signal. Building or opening the application neither installs nor starts this root process.

A future installation mechanism will need to define how the daemon starts, how it is removed, and how the user authorizes installation. `src/Resources/dev.mactower.daemon.plist` is a launchd template; it is not registered or installed by the build. No installer or privilege escalation mechanism is included in the scaffold. Apple's [Service Management documentation](https://developer.apple.com/documentation/servicemanagement) is the reference for evaluating that integration.

## Future metrics and controls

The product direction is to publish user-selected metrics, such as battery state or Codex usage limits, and offer narrowly defined controls to a smart-home dashboard or another local client. None of those collectors or actions is implemented yet. The data source and permission requirements for each capability must be verified independently.

No transport protocol or IPC mechanism has been implemented. Introducing either requires a concrete contract: which process owns each operation, what data crosses the boundary, how inputs are validated, and how failures are reported. Operations that need a user session should remain in that session; only operations that need elevated privileges should reach the root daemon.

The network service is intended to omit application-level authentication. Its trust boundary must therefore be enforced through explicitly selected interfaces and accepted local peers. RFC 1918 membership alone does not prove local-network membership, and IPv6 needs an explicit policy. Supported remote actions must be finite and must not accept arbitrary shell commands. See [SECURITY.md](../SECURITY.md).

## Build and validation

Swift Package Manager builds the executables and shared core. The Makefile provides the common development commands. Application packaging produces `dist/MacTower.app` with an ad-hoc development signature; this is not a notarized distribution or an installer.

Tests in `tests/MacTowerCoreTests/` exercise daemon command parsing without obtaining root privileges or changing the machine's permissions. Native UI and future privileged integration require separate, documented validation; passing unit tests alone does not establish that those integrations work.
