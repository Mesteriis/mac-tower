# Contributing

MacTower is an early scaffold. Keep changes focused and describe the behavior being added, including any new macOS permissions or service privileges.

## Development workflow

1. Use macOS 14 or later and Swift 6.0 or later.
2. Put production Swift code and helper scripts in `src/`, and tests in `tests/`.
3. Add regression coverage for meaningful behavior changes.
4. Run `make format` and `make check` before submitting a change.
5. Update documentation when commands, configuration, permissions, or observable behavior change.

Keep the user-session application and root daemon separate. New privileged operations need a concrete reason to run as root. Shared logic should be testable without launching the UI or obtaining root privileges.

Tests must not install services, modify system settings, request macOS permissions, or depend on a live network. Document any manual validation required for native UI or privileged behavior.

## Pull requests

Describe the problem, the resulting behavior, and the checks actually run. Call out checks that were skipped and why. Avoid unrelated cleanup, generated build output, machine-specific configuration, credentials, and signing material.

Before adding a network endpoint or remote action, review [SECURITY.md](SECURITY.md) and [the architecture](docs/architecture.md). LAN restrictions and privilege boundaries are part of the feature, not follow-up work.

Contributions are provided under the repository's [MIT license](LICENSE).
