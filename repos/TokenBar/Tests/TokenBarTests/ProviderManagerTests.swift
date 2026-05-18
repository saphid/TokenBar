import XCTest
@testable import TokenBarLib

// MARK: - Test Helpers

/// A fake provider for testing — returns a canned snapshot.
struct FakeProvider: UsageProvider {
    let id: String
    let name: String
    let iconSymbol = "testtube.2"
    let dashboardURL: URL? = nil
    let isTrackable: Bool

    func isAvailable() async -> Bool { true }

    func fetchUsage() async throws -> UsageSnapshot {
        UsageSnapshot(
            providerId: id,
            quotas: [UsageQuota(percentUsed: 42, label: "Monthly", detailText: "42/100")],
            capturedAt: Date(),
            accountTier: nil
        )
    }
}

/// Creates an isolated ProviderManager with its own UserDefaults suite.
/// Installs a fake provider factory so tests don't depend on real providers.
func makeTestManager(suiteName: String) -> ProviderManager {
    let suite = UserDefaults(suiteName: suiteName)!
    // Clear any leftover state
    suite.removePersistentDomain(forName: suiteName)

    let manager = ProviderManager(defaults: suite)
    manager.providerFactory = { config in
        let isTrackable = ProviderCatalog.type(for: config.typeId)?.category == .trackable
        return FakeProvider(id: config.id, name: config.label, isTrackable: isTrackable)
    }
    return manager
}

func cursorConfig(enabled: Bool = false) -> ProviderInstanceConfig {
    ProviderInstanceConfig(
        id: "cursor",
        typeId: "cursor",
        label: "Cursor",
        enabled: enabled,
        isAutoDetected: true,
        keychainKey: nil,
        organizationId: nil,
        monthlyBudget: nil
    )
}

func detectedConfig(id: String = "claude-code", enabled: Bool = false) -> ProviderInstanceConfig {
    ProviderInstanceConfig(
        id: id,
        typeId: "claude-code",
        label: "Claude Code",
        enabled: enabled,
        isAutoDetected: true,
        keychainKey: nil,
        organizationId: nil,
        monthlyBudget: nil
    )
}

// MARK: - Tests

final class ProviderManagerToggleTests: XCTestCase {

    // MARK: - Toggle On fires visibility callback

    func testToggleOn_firesVisibilityTrue() {
        let manager = makeTestManager(suiteName: "test.toggle.on")
        let config = cursorConfig(enabled: false)
        manager.addInstance(config) // starts disabled, so no visibility callback

        var callbackLog: [(String, Bool)] = []
        manager.onProviderVisibilityChange = { id, visible in
            callbackLog.append((id, visible))
        }

        manager.toggleProvider("cursor", enabled: true)

        XCTAssertEqual(callbackLog.count, 1, "Should fire exactly one visibility callback")
        XCTAssertEqual(callbackLog[0].0, "cursor")
        XCTAssertTrue(callbackLog[0].1, "Should fire with visible=true")

        // Verify the config was actually updated
        let updated = manager.instanceConfigs.first { $0.id == "cursor" }
        XCTAssertTrue(updated?.enabled == true, "Config should be enabled after toggle")
    }

    // MARK: - Toggle Off fires visibility callback

    func testToggleOff_firesVisibilityFalse() {
        let manager = makeTestManager(suiteName: "test.toggle.off")
        let config = cursorConfig(enabled: true)

        // Wire callback before addInstance so we capture the initial show
        var callbackLog: [(String, Bool)] = []
        manager.onProviderVisibilityChange = { id, visible in
            callbackLog.append((id, visible))
        }

        manager.addInstance(config) // fires (cursor, true)
        callbackLog.removeAll() // clear the add callback

        manager.toggleProvider("cursor", enabled: false)

        XCTAssertEqual(callbackLog.count, 1, "Should fire exactly one visibility callback")
        XCTAssertEqual(callbackLog[0].0, "cursor")
        XCTAssertFalse(callbackLog[0].1, "Should fire with visible=false")

        let updated = manager.instanceConfigs.first { $0.id == "cursor" }
        XCTAssertTrue(updated?.enabled == false, "Config should be disabled after toggle")
    }

    // MARK: - Toggle same state is no-op

    func testToggleSameState_noCallback() {
        let manager = makeTestManager(suiteName: "test.toggle.noop")
        let config = cursorConfig(enabled: true)

        var callbackLog: [(String, Bool)] = []
        manager.onProviderVisibilityChange = { id, visible in
            callbackLog.append((id, visible))
        }

        manager.addInstance(config) // fires (cursor, true)
        callbackLog.removeAll()

        // Toggle to same state — already enabled, toggle enabled again
        manager.toggleProvider("cursor", enabled: true)

        XCTAssertTrue(callbackLog.isEmpty, "Should not fire callback when toggling to same state")
    }

    // MARK: - Rapid toggle on/off/on

    func testRapidToggle_correctCallbackSequence() {
        let manager = makeTestManager(suiteName: "test.toggle.rapid")
        let config = cursorConfig(enabled: false)
        manager.addInstance(config)

        var callbackLog: [(String, Bool)] = []
        manager.onProviderVisibilityChange = { id, visible in
            callbackLog.append((id, visible))
        }

        manager.toggleProvider("cursor", enabled: true)   // disabled → enabled
        manager.toggleProvider("cursor", enabled: false)  // enabled → disabled
        manager.toggleProvider("cursor", enabled: true)   // disabled → enabled

        XCTAssertEqual(callbackLog.count, 3)
        XCTAssertTrue(callbackLog[0].1)   // show
        XCTAssertFalse(callbackLog[1].1)  // hide
        XCTAssertTrue(callbackLog[2].1)   // show again
    }

    // MARK: - Toggle nonexistent provider

    func testToggleNonexistent_noEffect() {
        let manager = makeTestManager(suiteName: "test.toggle.ghost")

        var callbackLog: [(String, Bool)] = []
        manager.onProviderVisibilityChange = { id, visible in
            callbackLog.append((id, visible))
        }

        manager.toggleProvider("nonexistent", enabled: true)

        XCTAssertTrue(callbackLog.isEmpty, "Should not fire callback for nonexistent provider")
        XCTAssertTrue(manager.instanceConfigs.isEmpty)
    }
}

final class ProviderManagerAddRemoveTests: XCTestCase {

    // MARK: - Add enabled instance fires visibility

    func testAddEnabled_firesVisibility() {
        let manager = makeTestManager(suiteName: "test.add.enabled")
        var callbackLog: [(String, Bool)] = []
        manager.onProviderVisibilityChange = { id, visible in
            callbackLog.append((id, visible))
        }

        let config = cursorConfig(enabled: true)
        manager.addInstance(config)

        XCTAssertEqual(callbackLog.count, 1)
        XCTAssertEqual(callbackLog[0].0, "cursor")
        XCTAssertTrue(callbackLog[0].1)
        XCTAssertEqual(manager.instanceConfigs.count, 1)
        XCTAssertNotNil(manager.providers["cursor"], "Provider should be instantiated")
    }

    // MARK: - Add disabled instance does not fire visibility

    func testAddDisabled_noVisibility() {
        let manager = makeTestManager(suiteName: "test.add.disabled")
        var callbackLog: [(String, Bool)] = []
        manager.onProviderVisibilityChange = { id, visible in
            callbackLog.append((id, visible))
        }

        let config = cursorConfig(enabled: false)
        manager.addInstance(config)

        XCTAssertTrue(callbackLog.isEmpty, "Disabled instance should not fire visibility")
        XCTAssertEqual(manager.instanceConfigs.count, 1)
        XCTAssertNotNil(manager.providers["cursor"], "Provider should still be instantiated")
    }

    // MARK: - Remove fires visibility false

    func testRemove_firesVisibilityFalse() {
        let manager = makeTestManager(suiteName: "test.remove")
        let config = cursorConfig(enabled: true)
        manager.addInstance(config)

        var callbackLog: [(String, Bool)] = []
        manager.onProviderVisibilityChange = { id, visible in
            callbackLog.append((id, visible))
        }

        manager.removeInstance("cursor")

        XCTAssertEqual(callbackLog.count, 1)
        XCTAssertEqual(callbackLog[0].0, "cursor")
        XCTAssertFalse(callbackLog[0].1, "Remove should fire visible=false")

        // Verify cleanup
        XCTAssertTrue(manager.instanceConfigs.isEmpty)
        XCTAssertNil(manager.providers["cursor"])
        XCTAssertNil(manager.snapshots["cursor"])
        XCTAssertNil(manager.errors["cursor"])
        XCTAssertFalse(manager.loadingProviders.contains("cursor"))
    }

    // MARK: - Remove nonexistent fires visibility false (defensive)

    func testRemoveNonexistent_stillFiresCallback() {
        let manager = makeTestManager(suiteName: "test.remove.ghost")
        var callbackLog: [(String, Bool)] = []
        manager.onProviderVisibilityChange = { id, visible in
            callbackLog.append((id, visible))
        }

        manager.removeInstance("nonexistent")

        // removeInstance fires onProviderVisibilityChange unconditionally
        XCTAssertEqual(callbackLog.count, 1)
        XCTAssertFalse(callbackLog[0].1)
    }

    // MARK: - Add then remove then add

    func testAddRemoveAdd_correctState() {
        let manager = makeTestManager(suiteName: "test.add.remove.add")
        var callbackLog: [(String, Bool)] = []
        manager.onProviderVisibilityChange = { id, visible in
            callbackLog.append((id, visible))
        }

        let config = cursorConfig(enabled: true)
        manager.addInstance(config)   // (cursor, true)
        manager.removeInstance("cursor")  // (cursor, false)
        manager.addInstance(config)   // (cursor, true)

        XCTAssertEqual(callbackLog.count, 3)
        XCTAssertTrue(callbackLog[0].1)
        XCTAssertFalse(callbackLog[1].1)
        XCTAssertTrue(callbackLog[2].1)

        XCTAssertEqual(manager.instanceConfigs.count, 1)
        XCTAssertNotNil(manager.providers["cursor"])
    }
}

final class ProviderManagerPersistenceTests: XCTestCase {

    // MARK: - Toggle persists to UserDefaults

    func testToggle_persistsToDefaults() {
        let suiteName = "test.persist.toggle"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)

        let manager = makeTestManager(suiteName: suiteName)
        manager.addInstance(cursorConfig(enabled: false))
        manager.toggleProvider("cursor", enabled: true)

        // Read back from UserDefaults
        let data = suite.data(forKey: ProviderManager.configsKey)
        XCTAssertNotNil(data)
        let configs = try! JSONDecoder().decode([ProviderInstanceConfig].self, from: data!)
        XCTAssertEqual(configs.count, 1)
        XCTAssertTrue(configs[0].enabled, "Persisted config should show enabled=true")
    }

    // MARK: - Configs survive manager recreation

    func testConfigs_surviveRecreation() {
        let suiteName = "test.persist.recreate"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)

        // Create manager, add config, toggle on
        let manager1 = ProviderManager(defaults: suite)
        manager1.providerFactory = { config in
            FakeProvider(id: config.id, name: config.label, isTrackable: true)
        }
        manager1.addInstance(cursorConfig(enabled: true))

        // Create a new manager from the same defaults
        let manager2 = ProviderManager(defaults: suite)
        XCTAssertEqual(manager2.instanceConfigs.count, 1)
        XCTAssertEqual(manager2.instanceConfigs[0].id, "cursor")
        XCTAssertTrue(manager2.instanceConfigs[0].enabled)
    }
}

final class ProviderManagerUpdateTests: XCTestCase {

    // MARK: - Update from disabled to enabled shows provider

    func testUpdate_disabledToEnabled_firesVisibility() {
        let manager = makeTestManager(suiteName: "test.update.enable")
        let config = cursorConfig(enabled: false)
        manager.addInstance(config)

        var callbackLog: [(String, Bool)] = []
        manager.onProviderVisibilityChange = { id, visible in
            callbackLog.append((id, visible))
        }

        var updated = config
        updated.enabled = true
        manager.updateInstance(updated)

        XCTAssertEqual(callbackLog.count, 1)
        XCTAssertTrue(callbackLog[0].1, "Should show provider after enabling via update")
    }

    // MARK: - Update label doesn't change visibility

    func testUpdate_labelOnly_noVisibilityChange() {
        let manager = makeTestManager(suiteName: "test.update.label")
        let config = cursorConfig(enabled: true)

        var callbackLog: [(String, Bool)] = []
        manager.onProviderVisibilityChange = { id, visible in
            callbackLog.append((id, visible))
        }

        manager.addInstance(config) // fires (cursor, true)
        callbackLog.removeAll()

        var updated = config
        updated.label = "My Custom Cursor"
        manager.updateInstance(updated)

        XCTAssertTrue(callbackLog.isEmpty, "Label-only change should not trigger visibility change")
        XCTAssertEqual(manager.instanceConfigs[0].label, "My Custom Cursor")
    }

    // MARK: - Update nonexistent is no-op

    func testUpdate_nonexistent_noOp() {
        let manager = makeTestManager(suiteName: "test.update.ghost")
        var callbackLog: [(String, Bool)] = []
        manager.onProviderVisibilityChange = { id, visible in
            callbackLog.append((id, visible))
        }

        let config = cursorConfig(enabled: true)
        manager.updateInstance(config) // no such instance

        XCTAssertTrue(callbackLog.isEmpty)
        XCTAssertTrue(manager.instanceConfigs.isEmpty)
    }
}

final class ProviderInstanceConfigEquatableTests: XCTestCase {

    // MARK: - Equatable compares all fields

    func testEquatable_differentEnabled_notEqual() {
        let a = ProviderInstanceConfig(
            id: "cursor", typeId: "cursor", label: "Cursor",
            enabled: true, isAutoDetected: false,
            keychainKey: nil, organizationId: nil, monthlyBudget: nil
        )
        var b = a
        b.enabled = false

        XCTAssertNotEqual(a, b, "Configs with different enabled state must NOT be equal — this was the root cause of the flaky toggle bug")
    }

    func testEquatable_differentLabel_notEqual() {
        let a = ProviderInstanceConfig(
            id: "cursor", typeId: "cursor", label: "Cursor",
            enabled: true, isAutoDetected: false,
            keychainKey: nil, organizationId: nil, monthlyBudget: nil
        )
        var b = a
        b.label = "My Cursor"

        XCTAssertNotEqual(a, b, "Configs with different labels must NOT be equal")
    }

    func testEquatable_sameValues_equal() {
        let a = ProviderInstanceConfig(
            id: "cursor", typeId: "cursor", label: "Cursor",
            enabled: true, isAutoDetected: false,
            keychainKey: nil, organizationId: nil, monthlyBudget: nil
        )
        let b = a

        XCTAssertEqual(a, b, "Identical configs should be equal")
    }
}

final class ProviderManagerMultiInstanceTests: XCTestCase {

    // MARK: - User-reported scenario: enable cursor, enable codex, disable codex → cursor stays

    func testUserScenario_enableCursorEnableCodexDisableCodex_cursorStaysVisible() {
        let manager = makeTestManager(suiteName: "test.multi.scenario")

        // Start with both disabled (like after auto-detection on first run)
        let cursor = cursorConfig(enabled: true) // Cursor starts enabled (auto-detected trackable)
        let codex = ProviderInstanceConfig(
            id: "codex", typeId: "codex", label: "Codex",
            enabled: false, isAutoDetected: true,
            keychainKey: nil, organizationId: nil, monthlyBudget: nil
        )
        manager.addInstance(cursor)
        manager.addInstance(codex)

        var visibilityLog: [(String, Bool)] = []
        manager.onProviderVisibilityChange = { id, visible in
            visibilityLog.append((id, visible))
        }

        // Step 1: Enable codex
        manager.toggleProvider("codex", enabled: true)
        XCTAssertEqual(visibilityLog.count, 1)
        XCTAssertEqual(visibilityLog[0].0, "codex")
        XCTAssertTrue(visibilityLog[0].1)

        // Step 2: Disable codex
        manager.toggleProvider("codex", enabled: false)
        XCTAssertEqual(visibilityLog.count, 2)
        XCTAssertEqual(visibilityLog[1].0, "codex")
        XCTAssertFalse(visibilityLog[1].1)

        // Cursor's state must be completely unaffected
        let cursorState = manager.instanceConfigs.first { $0.id == "cursor" }
        XCTAssertTrue(cursorState!.enabled, "Cursor must remain enabled after toggling codex")

        // No visibility callback should have fired for cursor at all
        let cursorCallbacks = visibilityLog.filter { $0.0 == "cursor" }
        XCTAssertTrue(cursorCallbacks.isEmpty, "No visibility callbacks should fire for cursor when only codex is toggled")
    }

    // MARK: - Toggle doesn't accidentally read wrong config index

    func testToggle_doesNotCorruptOtherConfigs() {
        let manager = makeTestManager(suiteName: "test.multi.corrupt")

        // Add 5 providers
        let configs = [
            cursorConfig(enabled: true),
            detectedConfig(id: "claude-code", enabled: false),
            ProviderInstanceConfig(id: "codex", typeId: "codex", label: "Codex",
                enabled: false, isAutoDetected: true,
                keychainKey: nil, organizationId: nil, monthlyBudget: nil),
            ProviderInstanceConfig(id: "gemini", typeId: "gemini", label: "Gemini",
                enabled: false, isAutoDetected: true,
                keychainKey: nil, organizationId: nil, monthlyBudget: nil),
            ProviderInstanceConfig(id: "kilo-code", typeId: "kilo-code", label: "Kilo Code",
                enabled: false, isAutoDetected: true,
                keychainKey: nil, organizationId: nil, monthlyBudget: nil),
        ]
        for c in configs { manager.addInstance(c) }

        // Toggle each one on, one at a time
        for c in configs where !c.enabled {
            manager.toggleProvider(c.id, enabled: true)
        }

        // Verify ALL are enabled
        for c in manager.instanceConfigs {
            XCTAssertTrue(c.enabled, "\(c.id) should be enabled but is \(c.enabled)")
        }

        // Toggle just codex off
        manager.toggleProvider("codex", enabled: false)

        // Verify only codex is disabled, all others still enabled
        for c in manager.instanceConfigs {
            if c.id == "codex" {
                XCTAssertFalse(c.enabled, "codex should be disabled")
            } else {
                XCTAssertTrue(c.enabled, "\(c.id) should still be enabled after toggling codex off")
            }
        }
    }

    // MARK: - Multiple providers independently toggle

    func testMultipleProviders_independentToggle() {
        let manager = makeTestManager(suiteName: "test.multi.toggle")

        let cursor = cursorConfig(enabled: false)
        let claude = detectedConfig(id: "claude-code", enabled: false)
        manager.addInstance(cursor)
        manager.addInstance(claude)

        var callbackLog: [(String, Bool)] = []
        manager.onProviderVisibilityChange = { id, visible in
            callbackLog.append((id, visible))
        }

        // Enable cursor only
        manager.toggleProvider("cursor", enabled: true)

        XCTAssertEqual(callbackLog.count, 1)
        XCTAssertEqual(callbackLog[0].0, "cursor")
        XCTAssertTrue(callbackLog[0].1)

        // Enable claude-code
        manager.toggleProvider("claude-code", enabled: true)

        XCTAssertEqual(callbackLog.count, 2)
        XCTAssertEqual(callbackLog[1].0, "claude-code")
        XCTAssertTrue(callbackLog[1].1)

        // Disable cursor — should not affect claude-code
        manager.toggleProvider("cursor", enabled: false)

        XCTAssertEqual(callbackLog.count, 3)
        XCTAssertEqual(callbackLog[2].0, "cursor")
        XCTAssertFalse(callbackLog[2].1)

        // Verify final state
        let cursorConfig = manager.instanceConfigs.first { $0.id == "cursor" }
        let claudeConfig = manager.instanceConfigs.first { $0.id == "claude-code" }
        XCTAssertFalse(cursorConfig!.enabled)
        XCTAssertTrue(claudeConfig!.enabled)
    }
}
