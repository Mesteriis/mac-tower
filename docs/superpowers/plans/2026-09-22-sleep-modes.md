# Three-Mode Sleep Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent three-position Mac sleep policy controlled from the MacTower menu and settings, with the root daemon as the only owner of public IOKit power assertions.

**Architecture:** A shared finite contract represents requested, persisted, and applied power modes. A focused `MacTowerPowerControl` target owns persistence and IOKit assertion lifetimes behind injected protocols; the authenticated daemon XPC contract exposes status and one finite mutation. The menu-bar app renders the daemon-confirmed state and never creates a second local assertion owner.

**Tech Stack:** Swift 6, macOS 14+, SwiftPM, Swift Testing, SwiftUI, Foundation XPC, IOKit `IOPMLib`, existing `PrivateFileStore` and trust-manifest boundary.

**Spec:** `docs/superpowers/specs/2026-09-22-sleep-modes-design.md`

## Global Constraints

- Source remains under `src`, tests under `tests`, and user commands remain in the existing `Makefile`.
- The only modes are `normal`, `keepMacAwake`, and `keepMacAndDisplaysAwake`; default is `normal`, with no timers.
- Do not modify `pmset`, invoke `caffeinate`, declare user activity, wake a display, emulate input, or add a dependency.
- Do not override manual sleep, lid-close sleep, critical-battery protection, screen locking, or Dark Wake behavior.
- The root LaunchDaemon is the sole assertion owner; the GUI communicates only over the existing UID- and cdhash-authenticated XPC channel.
- Do not add HTTP or MQTT mutation routes. HTTP remains read-only.
- `normal` removes every MacTower-owned assertion even when persistence fails; the status must expose that the old persisted mode can return after restart.
- A non-normal persistence failure leaves the current assertion state unchanged. Replacement assertion creation precedes old assertion release.
- Build and automated tests must never take a real power assertion; only the production backend may call IOKit.
- AI quota notifications remain out of this plan until their delivery channels are separately designed.

## Review Focus

- A malformed or future `power-control.json` must produce `normal` with an explicit `invalidSettings` issue, without overwriting the file or stopping AI/network service; Task 2 pins this.
- A `normal` persistence failure must still release all tracked assertions and report requested/applied `normal` while preserving the previous persisted value; Task 2 pins this.
- A replacement create failure or old-handle release failure must preserve every still-live handle in memory and report the real partial state without duplicate acquisitions; Task 2 pins this.
- An XPC timeout or late reply must not optimistically change UI state or retry the mutation; Task 3 pins this through the existing reply ledger and a client-state reducer test.
- A graceful SIGTERM must release assertions before potentially slow MQTT/network teardown, while a force-killed daemon relies on process-owner cleanup and reapplies the saved mode after launchd restart; Task 3 pins ordering with an injected lifecycle recorder, and Task 4 records the manual check.

---

### Task 1: Finite shared power contract

**Files:**
- Modify: `src/MacTowerCore/ManagementContract.swift`
- Create: `tests/MacTowerCoreTests/PowerControlContractTests.swift`

**Interfaces:**
- Consumes: Existing `ManagementEnvelope`, `ManagementOperation`, `DaemonStatus`, and Codable XPC payload convention.
- Produces: `PowerMode`, `PowerControlIssue`, `PowerControlStatus`, `SetPowerModeRequest`, `ManagementOperation.setPowerMode`, and optional `DaemonStatus.powerControl` (`nil` means an older or not-yet-composed service response, never `normal`).

- [ ] **Step 1: Write failing contract tests**

Create `PowerControlContractTests.swift` with Swift Testing cases that pin all raw values, reject an unknown mode, round-trip every status field, and prove the finite management operation decodes while `run_command` does not:

```swift
import Foundation
import Testing
@testable import MacTowerCore

@Suite("Power control contract")
struct PowerControlContractTests {
    @Test func modesAreFiniteAndCodable() throws {
        #expect(PowerMode.allCases == [.normal, .keepMacAwake, .keepMacAndDisplaysAwake])
        for mode in PowerMode.allCases {
            #expect(try JSONDecoder().decode(PowerMode.self, from: JSONEncoder().encode(mode)) == mode)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PowerMode.self, from: Data(#""future-mode""#.utf8))
        }
    }

    @Test func statusSeparatesRequestedPersistedAndApplied() throws {
        let value = PowerControlStatus(
            requestedMode: .normal,
            persistedMode: .keepMacAwake,
            appliedMode: .normal,
            issue: .persistenceFailed)
        #expect(try JSONDecoder().decode(PowerControlStatus.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func setModeOperationIsFinite() throws {
        let request = SetPowerModeRequest(mode: .keepMacAndDisplaysAwake)
        let envelope = ManagementEnvelope(
            operation: .setPowerMode, payload: try JSONEncoder().encode(request))
        #expect(try JSONDecoder().decode(ManagementEnvelope.self, from: JSONEncoder().encode(envelope)).operation == .setPowerMode)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ManagementEnvelope.self,
                from: Data(#"{"operation":"run_command","payload":null}"#.utf8))
        }
    }
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `./src/scripts/test.sh --filter PowerControlContractTests`

Expected: compile failure because `PowerMode`, `PowerControlStatus`, and `.setPowerMode` do not exist.

- [ ] **Step 3: Add the minimal shared types**

In `ManagementContract.swift`, add the exact finite types and the new status field:

```swift
public enum PowerMode: String, Codable, CaseIterable, Equatable, Sendable {
    case normal
    case keepMacAwake = "keep_mac_awake"
    case keepMacAndDisplaysAwake = "keep_mac_and_displays_awake"
}

public enum PowerControlIssue: String, Codable, Equatable, Sendable {
    case invalidSettings = "invalid_settings"
    case persistenceFailed = "persistence_failed"
    case assertionCreateFailed = "assertion_create_failed"
    case assertionReleaseFailed = "assertion_release_failed"
}

public struct PowerControlStatus: Codable, Equatable, Sendable {
    public let requestedMode: PowerMode
    public let persistedMode: PowerMode?
    public let appliedMode: PowerMode
    public let issue: PowerControlIssue?

    public init(
        requestedMode: PowerMode,
        persistedMode: PowerMode?,
        appliedMode: PowerMode,
        issue: PowerControlIssue? = nil
    ) {
        self.requestedMode = requestedMode
        self.persistedMode = persistedMode
        self.appliedMode = appliedMode
        self.issue = issue
    }
}

public struct SetPowerModeRequest: Codable, Equatable, Sendable {
    public let mode: PowerMode
    public init(mode: PowerMode) { self.mode = mode }
}
```

Add `case setPowerMode = "set_power_mode"` to `ManagementOperation`, and add
`powerControl: PowerControlStatus?` to `DaemonStatus` with a default initializer
argument of `nil`. A missing decoded field remains `nil` for compatibility and
must render as unknown/unavailable; Task 3 composes the real daemon-owned status.

- [ ] **Step 4: Run focused contract and existing management tests**

Run: `./src/scripts/test.sh --filter 'PowerControlContractTests|ManagementTests'`

Expected: PASS, including unknown-operation rejection and all existing trust-boundary tests.

- [ ] **Step 5: Commit the contract slice**

```bash
git add src/MacTowerCore/ManagementContract.swift tests/MacTowerCoreTests/PowerControlContractTests.swift
git commit -m "feat: add finite sleep mode management contract"
```

### Task 2: Persistent, testable assertion owner

**Files:**
- Modify: `Package.swift`
- Create: `src/MacTowerPowerControl/PowerAssertionBackend.swift`
- Create: `src/MacTowerPowerControl/IOKitPowerAssertionBackend.swift`
- Create: `src/MacTowerPowerControl/PowerModeStore.swift`
- Create: `src/MacTowerPowerControl/PowerControlService.swift`
- Create: `tests/MacTowerPowerControlTests/PowerControlServiceTests.swift`

**Interfaces:**
- Consumes: `PowerMode`, `PowerControlStatus`, `PowerControlIssue`, and `PrivateFileStore` from `MacTowerCore`.
- Produces: `PowerAssertionKind`, `PowerAssertionBackend.acquire(_:) -> UInt32`, `PowerAssertionBackend.release(_:)`, `PowerModeStore.load()/save(_:)`, `FilePowerModeStore`, `IOKitPowerAssertionBackend`, and the serialized `PowerControlService` API `status()`, `setMode(_:)`, and `stop()`.

- [ ] **Step 1: Add the target skeleton and exhaustive fake-backend tests**

Add a `MacTowerPowerControl` library target depending on `MacTowerCore`, linked with IOKit, add it to the daemon dependencies, and add `MacTowerPowerControlTests`. In the test file define `RecordingBackend` and `MemoryModeStore` that can fail individual acquire/release/load/save calls without touching IOKit. Cover:

```swift
@Test(arguments: [
    (PowerMode.normal, PowerMode.keepMacAwake),
    (.normal, .keepMacAndDisplaysAwake),
    (.keepMacAwake, .normal),
    (.keepMacAwake, .keepMacAndDisplaysAwake),
    (.keepMacAndDisplaysAwake, .normal),
    (.keepMacAndDisplaysAwake, .keepMacAwake),
])
func transitions(from: PowerMode, to: PowerMode) throws { /* assert call order and status */ }
```

Also add explicit cases for the three same-mode transitions, unknown/malformed stored data, load failure, non-normal save failure, normal save failure, acquire failure, release failure, retry after each partial failure, concurrent calls serializing, startup restoration, and `stop()` releasing every tracked handle. Assert that replacing one non-normal mode records `acquire(new)` before `release(old)`.

- [ ] **Step 2: Run the power target tests and verify RED**

Run: `./src/scripts/test.sh --filter PowerControlServiceTests`

Expected: compile failure because the new target interfaces are not implemented.

- [ ] **Step 3: Implement the injected boundaries**

Use these signatures:

```swift
public enum PowerAssertionKind: Equatable, Sendable {
    case preventUserIdleSystemSleep
    case preventUserIdleDisplaySleep
}

public protocol PowerAssertionBackend: Sendable {
    func acquire(_ kind: PowerAssertionKind) throws -> UInt32
    func release(_ id: UInt32) throws
}

public protocol PowerModeStore: Sendable {
    func load() throws -> PowerMode?
    func save(_ mode: PowerMode) throws
}
```

`FilePowerModeStore` stores a versioned Codable envelope such as `{ "version": 1, "mode": "keep_mac_awake" }` in `power-control.json` through `PrivateFileStore`. Missing data returns `nil`, which the service interprets as requested/persisted/applied `normal`; malformed/future data throws and is never rewritten by initialization.

- [ ] **Step 4: Implement serialized transition ownership**

Implement `PowerControlService` as a `final class: @unchecked Sendable` whose entire mutable state and backend/store calls are protected by one private `NSLock`. Its production initializer loads and reconciles immediately, while an injected initializer supports tests. Track every live assertion ID in memory rather than deriving liveness from the requested mode.

The transition table is exact:

```swift
private func kind(for mode: PowerMode) -> PowerAssertionKind? {
    switch mode {
    case .normal: nil
    case .keepMacAwake: .preventUserIdleSystemSleep
    case .keepMacAndDisplaysAwake: .preventUserIdleDisplaySleep
    }
}
```

For non-normal: save first; if saving fails, change nothing. Ensure the desired kind exists, then release all undesired tracked IDs. On create failure preserve the old live set. On release failure retain that ID and report `.assertionReleaseFailed`. For normal: attempt save, but regardless release all tracked IDs; report `.persistenceFailed` when the saved value remains old and `.assertionReleaseFailed` when any handle remains. If more than one failure is observable, issue priority is release, create, persistence, then invalid-settings; requested/persisted/applied fields retain the remaining detail. Repeated selection is idempotent. `stop()` releases all tracked IDs without changing the saved mode.

- [ ] **Step 5: Implement the production IOKit backend**

Map only:

```swift
case .preventUserIdleSystemSleep: kIOPMAssertPreventUserIdleSystemSleep
case .preventUserIdleDisplaySleep: kIOPMAssertPreventUserIdleDisplaySleep
```

Call `IOPMAssertionCreateWithName(type, kIOPMAssertionLevelOn, "MacTower …" as CFString, &id)` and require `kIOReturnSuccess`; call `IOPMAssertionRelease(id)` and require success. Use fixed reason strings only. Do not add timeouts, stronger assertion types, user-activity calls, wake scheduling, or inspection of other processes.

- [ ] **Step 6: Run the focused tests and then the full package tests**

Run: `./src/scripts/test.sh --filter PowerControlServiceTests`

Expected: PASS with fake backends only.

Run: `./src/scripts/test.sh`

Expected: all Swift tests PASS and no real assertion is created because no test constructs `IOKitPowerAssertionBackend`.

- [ ] **Step 7: Commit the assertion-owner slice**

```bash
git add Package.swift src/MacTowerPowerControl tests/MacTowerPowerControlTests
git commit -m "feat: own persistent sleep assertions in daemon module"
```

### Task 3: Authenticated daemon lifecycle and GUI controls

**Files:**
- Modify: `src/MacTowerDaemon/MacTowerDaemon.swift`
- Modify: `src/MacTowerDaemon/DaemonXPCServer.swift`
- Create: `src/MacTowerDaemon/DaemonManagementHandler.swift`
- Create: `src/MacTowerDaemon/DaemonLifecycle.swift`
- Modify: `src/MacTowerCore/ManagementContract.swift`
- Modify: `src/MacTowerApp/Services/DaemonClient.swift`
- Modify: `src/MacTowerApp/App/AppServices.swift`
- Modify: `src/MacTowerApp/App/MacTowerApp.swift`
- Modify: `src/MacTowerApp/Views/MenuBarView.swift`
- Modify: `src/MacTowerApp/Views/SettingsView.swift`
- Create: `src/MacTowerApp/Views/PowerModeLabels.swift`
- Create: `src/MacTowerApp/Views/PowerSettingsView.swift`
- Create: `tests/MacTowerAppTests/PowerModePresentationTests.swift`
- Create: `tests/MacTowerDaemonTests/PowerControlLifecycleTests.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: `PowerControlService` and all Task 1 DTOs; existing `DaemonConnectionFactory`, `XPCReplyLedger`, and authenticated `ManagementXPCService.handle` pattern.
- Produces: testable `DaemonManagementHandler`, testable release-before-network `DaemonLifecycle`, daemon status containing `powerControl`, finite `set_power_mode` handling, `DaemonClient.setPowerMode(_:)`, a three-item menu, and a three-position settings picker.

- [ ] **Step 1: Write failing daemon routing/lifecycle and presentation tests**

Extract the existing envelope switch into `DaemonManagementHandler`, injecting
`ManagementControlling` and `PowerControlServicing` protocols. Test that `.status`
copies the existing controller status fields and adds the exact power status,
`.setPowerMode` rejects missing/oversized/unknown payloads, and only calls
`setMode` once. Add `DaemonLifecycle.stop()` behind injected `PowerStopping` and
`NetworkStopping` protocols; its recorder test proves `power.stop` occurs before
`network.stop` for the code shared by SIGTERM and SIGINT.

In app tests, pin labels and explanatory copy for all modes and issues:

```swift
#expect(PowerMode.normal.displayName == "Normal")
#expect(PowerMode.keepMacAwake.displayName == "Keep Mac awake")
#expect(PowerMode.keepMacAndDisplaysAwake.displayName == "Keep Mac and displays awake")
#expect(PowerControlIssue.persistenceFailed.explanation.contains("restart"))
```

Add a small pure `PowerModePresentationState` reducer test: a selection becomes pending, a confirmed response replaces status, timeout/disconnect keeps the last confirmed status and exposes an error, and a late response for the expired request is ignored. This is the UI proof required by Review Focus; it must not create a second request automatically.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `./src/scripts/test.sh --filter 'PowerControlLifecycleTests|PowerModePresentationTests'`

Expected: compile failure because the daemon seam, labels, and presentation state do not exist.

- [ ] **Step 3: Wire the daemon and preserve shutdown ordering**

Construct one `PowerControlService` from the daemon root and inject it into
`DaemonXPCServer` through `DaemonManagementHandler`. Add `.setPowerMode` to the
handler switch, decode only `SetPowerModeRequest`, and return encoded
`PowerControlStatus`. For `.status`, copy `running`, HTTP/MQTT flags,
configuration, accounts, and active OAuth ID from `ManagementController.status()`
into a response whose `powerControl` comes from the same service instance.

On SIGTERM/SIGINT call `powerControl.stop()` before `await runtime.stop()`. A power initialization/storage error must create a normal/error status and continue starting AI/network services; only existing fatal service configuration errors retain their current exit behavior. Do not expose a new Mach service, LAN listener, MQTT subscription, shell command, or caller-selected assertion name.

- [ ] **Step 4: Add bounded GUI mutation state**

Refactor `DaemonClient`'s request transport to use its app-lifetime `XPCReplyLedger` with a three-second timeout for all management calls. `setPowerMode(_:)` sends exactly one `.setPowerMode` request, updates the reducer only from a decoded response, then refreshes status. On timeout/disconnect it keeps the last confirmed status, clears pending state, and surfaces a localized error; it never retries the write automatically.

Update `AppServices.stop()` to disconnect pending management replies. Do not hold an assertion in `AppServices` or UserDefaults.

- [ ] **Step 5: Add the menu and settings surfaces**

Add a menu `Sleep mode` after window controls. Its three buttons show a checkmark only against `daemon.status?.powerControl.requestedMode`; disable it when status is unknown, a mutation is pending, or the service is unavailable. Opening the menu refreshes status.

Add a General-section three-position `Picker` using `.segmented` where space permits; if localization/layout clips in the 720-point settings window, use an inline picker with the same three finite choices. Show requested, persisted, and applied mismatches plus the issue explanation. Include the warning that the non-normal modes use more energy and do not defeat lid-close/manual/critical-battery sleep.

- [ ] **Step 6: Run focused, package, and lifecycle tests**

Run: `./src/scripts/test.sh --filter 'PowerControl|PowerMode'`

Expected: all new contract, controller, lifecycle, and UI-state tests PASS.

Run: `make test`

Expected: all Swift tests and daemon/Claude/install lifecycle scripts PASS.

- [ ] **Step 7: Commit the integrated vertical slice**

```bash
git add Package.swift src/MacTowerCore src/MacTowerDaemon src/MacTowerApp tests/MacTowerAppTests tests/MacTowerDaemonTests
git commit -m "feat: expose three persistent sleep modes"
```

### Task 4: Documentation, static gates, and non-invasive acceptance handoff

**Files:**
- Modify: `README.md`
- Modify: `SECURITY.md`
- Modify: `docs/architecture.md`
- Modify: `docs/superpowers/specs/2026-09-22-sleep-modes-design.md` only if implementation evidence requires a precise correction

**Interfaces:**
- Consumes: Verified behavior and exact limitations from Tasks 1–3.
- Produces: User instructions, security/lifecycle guarantees, and honest automated/manual validation boundaries.

- [ ] **Step 1: Update public documentation**

Document the three modes, root-daemon ownership, menu/settings paths, battery warning, persistence across GUI exit/logout, uninstall-preserves/reinstall-restores behavior, and explicit limitations: already-off displays stay off; manual sleep, lid close, low-battery protection, lock, and Dark Wake are not overridden. State that changing the installed XPC contract requires `make install`.

In SECURITY, state that no LAN mutation was added, fixed assertion names contain no user data, and failures expose finite codes rather than raw IOKit payloads. In architecture, add `MacTowerPowerControl` and the flow `local GUI → authenticated XPC → root assertion owner → IOKit`.

- [ ] **Step 2: Run formatting and the complete project gate**

Run: `make format`

Run: `git diff --check`

Run: `make check`

Expected: exit 0; Swift build/tests, CLI tests, lifecycle dry-runs, strict formatter lint, plist validation, and shell syntax all PASS. Linker search-path warnings from the local Command Line Tools do not count as test failures when commands exit 0.

- [ ] **Step 3: Review the diff against the spec**

Run: `git diff --stat HEAD~3..HEAD && git status --short`

Inspect every changed file for: one assertion owner, no test constructing the native backend, no UserDefaults copy of the mode, no HTTP/MQTT writes, no secrets/user content in names or errors, exhaustive mode switches, release-before-network-stop ordering, and README/SECURITY agreement. Do not install the daemon or change this Mac's sleep state as part of automated validation.

- [ ] **Step 4: Commit documentation and final gate adjustments**

```bash
git add README.md SECURITY.md docs/architecture.md docs/superpowers/specs/2026-09-22-sleep-modes-design.md
git commit -m "docs: explain persistent MacTower sleep modes"
```

- [ ] **Step 5: Hand off manual acceptance separately**

Report exact automated command outcomes. Ask before running `make install` because it changes the installed root service and trusted hashes. After explicit approval, manually observe each mode, already-off display behavior, return to Normal, battery/AC switching, manual sleep/wake, lock/logout, daemon stop/restart, and assertion cleanup. Never induce critical battery or thermal conditions and never remove assertions belonging to other processes.
