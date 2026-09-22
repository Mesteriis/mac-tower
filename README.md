# MacTower

MacTower is a Swift scaffold for a macOS menu bar application and a separate root service. The project is intended to publish selected Mac metrics and expose a small set of controls to trusted devices on a local network, including smart-home dashboards.

**Current status:** the menu bar application, settings window, shared core, and daemon lifecycle are implemented. Metrics, network listeners, remote controls, and communication between the application and daemon are not implemented. No service is installed automatically.

## Requirements

- macOS 14 or later.
- Swift 6.0 or later, available through Xcode or the Command Line Tools.
- GNU Make or the `make` supplied with macOS.
- `swift-format` available through `xcrun` for formatting and validation.

## Development

```sh
make build
make test
make app
make run
```

`make app` creates `dist/MacTower.app` with an ad-hoc development signature. The app runs in the current user session and appears in the menu bar. Its settings let you show or hide the menu bar title and inspect the scaffold's current capabilities.

Quit the development app before using `make app` or `make release`; packaging refuses to overwrite a running bundle. `make run` handles stopping and restarting this checkout's app for you.

| Command | Purpose |
| --- | --- |
| `make build` | Build the Swift package. |
| `make test` | Run the package tests. |
| `make check` | Build, test, check formatting, and validate property lists and shell syntax. |
| `make format` | Format Swift source. |
| `make lint` | Check Swift formatting. |
| `make app` | Build the development application bundle. |
| `make run` | Build and open the development application. |
| `make release` | Build optimized binaries and an application bundle. |
| `make daemon-help` | Show daemon usage without root privileges. |

The daemon executable is `mac-tower-daemon`. Running its service loop requires effective user ID 0; `--help` and `--version` do not. It currently waits for termination signals and performs no network or privileged control operations. Launching the app does not install or start the daemon.

Development bundles are not notarized. There is no installer, automatic login registration, or root-service installation workflow yet.

`make test` uses Swift Testing and then runs CLI checks, including rejection of non-root daemon startup. Run tests as a regular user. The test helper accommodates Command Line Tools releases whose bundled TestingMacros plugin is outside SwiftPM's default search path; it does not change your selected toolchain or require full Xcode.

An inactive GitHub Actions template is provided at [docs/ci.yml.example](docs/ci.yml.example). To enable CI, a maintainer with workflow-write access can copy it to `.github/workflows/ci.yml`. It runs `make check` and builds the app on macOS. Automated CI is not enabled in this scaffold.

## Layout

```text
Package.swift
Makefile
src/
  MacTowerApp/       # SwiftUI menu bar application and settings
  MacTowerCore/      # Shared daemon command parsing
  MacTowerDaemon/    # Root-service executable
  Resources/        # Application property list and daemon launchd template
  scripts/          # Build and development helpers
tests/
  MacTowerCoreTests/ # Shared-core regression tests
docs/
  architecture.md
```

All application and helper code lives under `src/`; tests live under `tests/`. Package and build configuration remain at the repository root.

## Runtime model

The graphical application belongs to the logged-in user session. A separate daemon is reserved for operations that actually require root. Running the UI as root would not give it the correct graphical session, and root privileges do not replace macOS Accessibility or other user-consent requirements. Apple's [daemon design guidance](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/DesigningDaemons.html) describes the separation between system daemons and user sessions.

The intended network interface has no application-level authentication, by design, and is intended only for a trusted local network. No network interface exists in this scaffold. Future networking must explicitly restrict listening interfaces and accepted peers; a private IP address alone does not establish that a peer is on the intended local network. Remote actions must be explicitly enumerated and must not expose arbitrary shell execution.

See [architecture](docs/architecture.md), [security](SECURITY.md), and [contributing](CONTRIBUTING.md) for the development boundaries.

## License

MIT. See [LICENSE](LICENSE).
