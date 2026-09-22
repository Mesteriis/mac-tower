# Security

## Current scope

MacTower is a development scaffold, not a deployed remote-management service. It has no network listener, metric publisher, remote command endpoint, or application-to-daemon IPC. The application runs in the current user session. The daemon checks for effective user ID 0 before entering its idle service loop; help and version output are available without root.

There is no installer, privileged helper registration, or automatic service startup. No claim is made that local-network access controls have already been implemented.

## Intended deployment boundary

The intended service deliberately has no application-level authentication and is intended for a trusted local network. Any device allowed through the eventual network boundary must therefore be treated as authorized to use the exposed capabilities. Root execution increases the impact of a mistake in that boundary.

Before enabling networking, implementation must:

- Restrict the listening interfaces and accepted peer networks explicitly, including IPv6 behavior.
- Avoid treating all RFC 1918 addresses as one trusted LAN; private addresses can also belong to routed or VPN-connected networks.
- Expose a finite set of validated actions, with no arbitrary shell execution or unrestricted filesystem access.
- Keep user-session operations and root-only operations separate, with a defined IPC trust boundary if IPC is introduced.
- Publish only deliberately selected metrics and avoid logging or exposing credentials.

These are design requirements for future work, not implemented protections. The service is not intended to be exposed to the public Internet.

Root does not bypass macOS Accessibility authorization or other user-consent requirements. Window control must operate in the relevant logged-in user session and respect the permissions required by macOS.

## Reporting a vulnerability

Do not include credentials, personal data, or an unredacted exploit against a running installation in a public issue. Use the repository's private vulnerability reporting feature if it is available. If it is unavailable, open a public issue asking maintainers for a private reporting channel without disclosing sensitive details.

There is currently no published security-support window or response-time commitment.
