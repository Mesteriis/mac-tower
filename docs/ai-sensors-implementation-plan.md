# AI Sensors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` and implement each task with RED→GREEN tests.

**Goal:** Add multi-account Codex, Claude, and DeepSeek sensors, read-only LAN HTTP/MQTT publication, secure daemon management, and settings UI while leaving Cursor disabled as “Soon”.

**Architecture:** `MacTowerCore` owns secret-free snapshots, provider parsers, configuration validation, routing, discovery payloads, and process protocols. `MacTowerDaemon` owns durable collectors and network listeners. `MacTowerApp` owns user interaction and sends finite typed management operations over privileged XPC. A Claude bridge filters statusline input before persistence.

**Tech Stack:** Swift 6, macOS 14, SwiftPM, SwiftNIO/NIOHTTP1, MQTTNIO 2.x, Foundation URLSession/Process, NSXPCConnection, launchd.

## Global Constraints

- All source lives under `src/`; all tests live under `tests/`.
- LAN endpoints are read-only, disabled by default, IPv4-only, and explicit-interface/CIDR bound.
- Tokens, keys, email addresses, raw provider payloads, filesystem paths, and transcript data never enter public snapshots or logs.
- Codex credentials use one daemon-owned `CODEX_HOME` per account and the official App Server owns refresh.
- Claude retains only filtered rate-limit values and never imports consumer credentials.
- Cursor performs no discovery, credential access, or network calls.

## Review Focus

- Malformed or partially missing provider responses remain unavailable rather than becoming zero.
- Secret material cannot enter HTTP/MQTT encoders, logs, or persisted public snapshots.
- Untrusted HTTP peers and all non-GET methods are rejected.
- Duplicate Codex OAuth starts are serialized and profile paths cannot escape the root-owned account directory.
- MQTT reconnect/removal produces correct retained state, availability, and discovery cleanup messages.

### Task 1: Public sensor model and provider parsers

**Produces:** `AccountSnapshot`, quota/balance value types, freshness evaluation, Codex/Claude/DeepSeek parsers, public JSON encoding.

- [x] Add failing fixture-based tests for multi-window Codex quotas, Claude filtered statusline data, exact DeepSeek decimals, missing values, and secret-free encoding.
- [x] Implement the minimum model and parsers; run the focused tests and full suite.
- [x] Commit the green slice.

### Task 2: Configuration, collectors, and persistence

**Consumes:** Task 1 snapshot types. **Produces:** validated service configuration, safe root storage, poll scheduler, Codex App Server process client, DeepSeek client, Claude bridge ingestion.

- [x] Add failing tests for interval/CIDR/path validation, atomic snapshot retention, stale-on-error behavior, JSON-RPC framing, and bridge filtering.
- [x] Implement collectors and the standalone Claude bridge without reading real credentials in tests.
- [x] Commit the green slice.

### Task 3: Read-only HTTP and MQTT publication

**Consumes:** snapshot store/configuration. **Produces:** HTTP routes and NIO server, MQTT discovery/state message planner and MQTTNIO publisher.

- [x] Add failing tests for routes, peer ACL, non-GET rejection, absent-vs-zero JSON, HA discovery, reconnect/birth republish, and removal tombstones.
- [x] Add pinned compatible dependencies and implement the transports disabled by default.
- [x] Commit the green slice.

### Task 4: Privileged lifecycle, XPC, settings, and documentation

**Consumes:** daemon configuration/accounts. **Produces:** typed management API, launchd service packaging/install/uninstall, provider settings UI, service status, docs.

- [x] Add failing tests for finite management operations, account validation, installer dry-run behavior, and CLI lifecycle.
- [x] Implement XPC trust checks, hardened ad-hoc packaging, explicit administrator scripts/Make targets, and SwiftUI settings including Cursor “Soon”.
- [x] Update README, architecture, and security documentation; run `make check` plus packaging/install dry-run checks.
- [x] Commit the green slice and complete whole-branch review.
