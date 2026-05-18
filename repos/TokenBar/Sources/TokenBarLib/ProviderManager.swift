import Foundation
import Combine

/// Manages dynamic provider instances, polling, and state.
class ProviderManager: ObservableObject {
    @Published var instanceConfigs: [ProviderInstanceConfig] = []
    @Published var detectedTypeIds: Set<String> = []
    @Published var snapshots: [String: UsageSnapshot] = [:]
    @Published var errors: [String: String] = [:]
    @Published var loadingProviders: Set<String> = []
    @Published var pollInterval: TimeInterval
    @Published var sortMode: SortMode
    @Published var sortAscending: Bool
    @Published var showIconInMenuBar: Bool
    @Published var showNameInMenuBar: Bool
    @Published var appearanceMode: AppearanceMode
    @Published var devModeUnlocked: Bool

    private(set) var providers: [String: any UsageProvider] = [:]
    private var pollTimer: Timer?

    var onStatusItemUpdate: ((String, UsageSnapshot?) -> Void)?
    var onProviderVisibilityChange: ((String, Bool) -> Void)?
    /// Single callback for the unified menu bar item — fires when any state changes.
    var onStatusChange: (() -> Void)?
    /// Fires when a provider transitions from exhausted to available.
    /// Parameters: (providerId, optional screen origin for confetti burst)
    var onTokensRestored: ((String, CGPoint?) -> Void)?

    /// Tracks which providers had exhausted primary quotas on last poll.
    private var exhaustedProviders: Set<String> = []

    let defaults: UserDefaults
    /// Optional override for tests — if set, used instead of the built-in factory.
    var providerFactory: ((ProviderInstanceConfig) -> (any UsageProvider)?)?

    static let configsKey = "providerInstanceConfigs"
    static let pollIntervalKey = "pollInterval"
    static let sortModeKey = "sortMode"
    static let sortAscendingKey = "sortAscending"
    static let showIconInMenuBarKey = "showIconInMenuBar"
    static let showNameInMenuBarKey = "showNameInMenuBar"
    static let appearanceModeKey = "appearanceMode"
    static let devModeUnlockedKey = "devModeUnlocked"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedInterval = defaults.double(forKey: Self.pollIntervalKey)
        pollInterval = savedInterval > 0 ? savedInterval : 300

        // Sort settings
        if let rawSort = defaults.string(forKey: Self.sortModeKey),
           let mode = SortMode(rawValue: rawSort) {
            sortMode = mode
        } else {
            sortMode = .manual
        }
        sortAscending = defaults.object(forKey: Self.sortAscendingKey) as? Bool ?? true

        // Menu bar verbosity settings
        showIconInMenuBar = defaults.object(forKey: Self.showIconInMenuBarKey) as? Bool ?? true
        showNameInMenuBar = defaults.object(forKey: Self.showNameInMenuBarKey) as? Bool ?? true

        // Appearance
        if let rawAppearance = defaults.string(forKey: Self.appearanceModeKey),
           let mode = AppearanceMode(rawValue: rawAppearance) {
            appearanceMode = mode
        } else {
            appearanceMode = .system
        }

        devModeUnlocked = defaults.bool(forKey: Self.devModeUnlockedKey)

        loadConfigs()
    }

    // MARK: - Config Persistence

    private func loadConfigs() {
        guard let data = defaults.data(forKey: Self.configsKey),
              let saved = try? JSONDecoder().decode([ProviderInstanceConfig].self, from: data) else {
            return
        }
        instanceConfigs = saved
        sortConfigs()
    }

    private func sortConfigs() {
        // In manual mode, preserve the existing array order (user-controlled)
        guard sortMode != .manual else { return }

        instanceConfigs.sort { a, b in
            let aTrackable = ProviderCatalog.type(for: a.typeId)?.category == .trackable
            let bTrackable = ProviderCatalog.type(for: b.typeId)?.category == .trackable
            if aTrackable != bTrackable { return aTrackable }
            return a.label < b.label
        }
    }

    func saveConfigs() {
        if let data = try? JSONEncoder().encode(instanceConfigs) {
            defaults.set(data, forKey: Self.configsKey)
        }
    }

    func saveSortSettings() {
        defaults.set(sortMode.rawValue, forKey: Self.sortModeKey)
        defaults.set(sortAscending, forKey: Self.sortAscendingKey)
        onStatusChange?()
    }

    func saveMenuBarSettings() {
        defaults.set(showIconInMenuBar, forKey: Self.showIconInMenuBarKey)
        defaults.set(showNameInMenuBar, forKey: Self.showNameInMenuBarKey)
        onStatusChange?()
    }

    func saveAppearance() {
        defaults.set(appearanceMode.rawValue, forKey: Self.appearanceModeKey)
    }

    func saveDevMode() {
        defaults.set(devModeUnlocked, forKey: Self.devModeUnlockedKey)
    }

    // MARK: - Sorting

    func moveProviders(from source: IndexSet, to destination: Int) {
        instanceConfigs.move(fromOffsets: source, toOffset: destination)
        saveConfigs()
        onStatusChange?()
    }

    /// Labels for supplementary quotas that don't block primary access.
    private static let supplementaryLabels: Set<String> = ["Credits", "On-Demand"]

    /// Enabled configs sorted according to the active sort mode.
    var sortedEnabledConfigs: [ProviderInstanceConfig] {
        let enabled = instanceConfigs.filter(\.enabled)

        switch sortMode {
        case .manual:
            return enabled  // preserve array order

        case .mostAvailableNow:
            // Sort by the most constraining primary quota (highest percentUsed).
            // Providers with more remaining capacity sort first.
            // Exhausted providers (any primary at 100%) sort last.
            return enabled.sorted { a, b in
                let aAvail = availabilityNow(for: a.id)
                let bAvail = availabilityNow(for: b.id)
                return sortAscending ? aAvail > bAvail : aAvail < bAvail
            }

        case .mostAvailableLong:
            // Sort by the longest-term quota (furthest resetsAt, typically monthly).
            // Providers with more long-term headroom sort first.
            return enabled.sorted { a, b in
                let aAvail = availabilityLongTerm(for: a.id)
                let bAvail = availabilityLongTerm(for: b.id)
                return sortAscending ? aAvail > bAvail : aAvail < bAvail
            }

        case .resetTime:
            return enabled.sorted { a, b in
                let aReset = earliestReset(for: a.id) ?? .distantFuture
                let bReset = earliestReset(for: b.id) ?? .distantFuture
                return sortAscending ? aReset < bReset : aReset > bReset
            }

        case .alphabetical:
            return enabled.sorted { a, b in
                sortAscending ? a.label < b.label : a.label > b.label
            }
        }
    }

    /// How available is this provider *right now*?
    /// Returns percentRemaining of the most constraining primary quota.
    /// Exhausted providers return -1 (sort last). No data returns -2 (sort last).
    private func availabilityNow(for id: String) -> Double {
        guard let snapshot = snapshots[id] else { return -2 }
        let trackable = snapshot.quotas.filter { $0.percentUsed >= 0 }
        let primary = trackable.filter { !Self.supplementaryLabels.contains($0.label) }

        // If any primary quota is exhausted, this provider is blocked
        if primary.contains(where: { $0.percentUsed >= 100 }) { return -1 }

        // Most constraining = highest percentUsed → lowest percentRemaining
        guard let mostConstrained = primary.max(by: { $0.percentUsed < $1.percentUsed }) else {
            return -2  // no primary quotas (detectedOnly etc.)
        }
        return mostConstrained.percentRemaining
    }

    /// How available is this provider *long-term* (monthly)?
    /// Returns percentRemaining of the longest-term quota (furthest resetsAt).
    /// Falls back to the quota with most remaining if no reset dates.
    private func availabilityLongTerm(for id: String) -> Double {
        guard let snapshot = snapshots[id] else { return -2 }
        let trackable = snapshot.quotas.filter { $0.percentUsed >= 0 }
        let primary = trackable.filter { !Self.supplementaryLabels.contains($0.label) }
        guard !primary.isEmpty else { return -2 }

        // Longest-term = furthest resetsAt date
        let withReset = primary.filter { $0.resetsAt != nil }
        if let longestTerm = withReset.max(by: { ($0.resetsAt ?? .distantPast) < ($1.resetsAt ?? .distantPast) }) {
            return longestTerm.percentRemaining
        }

        // No reset dates — fall back to least-used quota
        if let leastUsed = primary.min(by: { $0.percentUsed < $1.percentUsed }) {
            return leastUsed.percentRemaining
        }
        return -2
    }

    private func earliestReset(for id: String) -> Date? {
        snapshots[id]?.quotas.compactMap(\.resetsAt).min()
    }

    /// Checks if a provider just transitioned from exhausted to available.
    private func checkTokenRestoration(_ id: String, newSnapshot: UsageSnapshot) {
        let wasExhausted = exhaustedProviders.contains(id)
        let primaryQuotas = newSnapshot.quotas.filter {
            $0.percentUsed >= 0 && !Self.supplementaryLabels.contains($0.label)
        }
        let isExhausted = primaryQuotas.contains { $0.percentUsed >= 100 }

        if isExhausted {
            exhaustedProviders.insert(id)
        } else {
            exhaustedProviders.remove(id)
        }

        if wasExhausted && !isExhausted && !primaryQuotas.isEmpty {
            TBLog.log("Tokens restored for \(id)!", category: "confetti")
            onTokensRestored?(id, nil)
        }
    }

    // MARK: - Provider Factory

    func createProvider(for config: ProviderInstanceConfig) -> (any UsageProvider)? {
        if let factory = providerFactory {
            return factory(config)
        }

        // Registry lookup replaces the old switch statement.
        // ProviderCatalog.allTypes is sourced from the registry, so if a type
        // isn't registered, it won't be in the catalog either — no fallback needed.
        guard let registeredType = ProviderRegistry.type(for: config.typeId) else { return nil }
        return registeredType.create(
            instanceId: config.id,
            label: config.label,
            config: config.asProviderConfig
        )
    }

    /// Whether a provider config should show a menu bar status item.
    /// Any enabled provider gets a menu bar icon — the "only trackable" filter
    /// is applied only during first-run auto-enable, not here.
    func shouldShowInMenuBar(_ config: ProviderInstanceConfig) -> Bool {
        config.enabled
    }

    // MARK: - Startup

    func performStartup() {
        Task {
            let detected = ProviderCatalog.detectAll()

            await MainActor.run {
                self.detectedTypeIds = detected
                self.mergeAutoDetected(detected)
                self.instantiateProviders()
                self.startPolling()
            }
        }
    }

    func mergeAutoDetected(_ detected: Set<String>) {
        let existingTypeIds = Set(instanceConfigs.map(\.typeId))
        let isFirstRun = defaults.data(forKey: Self.configsKey) == nil

        for typeId in detected {
            guard let typeInfo = ProviderCatalog.type(for: typeId) else { continue }

            if !typeInfo.supportsMultipleInstances && existingTypeIds.contains(typeId) {
                if let idx = instanceConfigs.firstIndex(where: { $0.typeId == typeId }) {
                    instanceConfigs[idx].isAutoDetected = true
                }
                continue
            }

            if typeInfo.supportsMultipleInstances && existingTypeIds.contains(typeId) {
                continue
            }

            // Codex: auto-create one instance per organization found in auth.json
            if typeId == "codex" {
                let orgs = CodexProvider.discoverOrganizations()
                if orgs.count > 1 {
                    TBLog.log("Codex: discovered \(orgs.count) organizations, creating per-org instances", category: "startup")
                    for org in orgs {
                        let slugged = org.title.lowercased()
                            .replacingOccurrences(of: " ", with: "-")
                            .replacingOccurrences(of: "[^a-z0-9\\-]", with: "", options: .regularExpression)
                        let instanceId = "codex-\(slugged)"
                        let label = "Codex \(org.title)"
                        let config = ProviderInstanceConfig(
                            id: instanceId,
                            typeId: "codex",
                            label: label,
                            enabled: isFirstRun && typeInfo.category == .trackable,
                            isAutoDetected: true,
                            codexOrgId: org.id
                        )
                        instanceConfigs.append(config)
                    }
                    continue
                }
                // Single org or none — fall through to create a plain "codex" instance
            }

            // Auto-enable trackable providers on first run; detected-only just get listed
            let config = ProviderInstanceConfig(
                id: typeId,
                typeId: typeId,
                label: typeInfo.defaultName,
                enabled: isFirstRun && typeInfo.category == .trackable,
                isAutoDetected: true,
                keychainKey: typeId == "openai" ? "openai_api_key" : nil,
                organizationId: nil,
                monthlyBudget: nil
            )
            instanceConfigs.append(config)
        }

        for i in instanceConfigs.indices {
            if instanceConfigs[i].isAutoDetected && !detected.contains(instanceConfigs[i].typeId) {
                instanceConfigs[i].isAutoDetected = false
            }
        }

        sortConfigs()
        saveConfigs()
    }

    func instantiateProviders() {
        TBLog.log("instantiateProviders: \(instanceConfigs.count) configs", category: "startup")
        for config in instanceConfigs {
            guard let provider = createProvider(for: config) else {
                TBLog.log("  SKIP \(config.id) — createProvider returned nil", category: "startup")
                continue
            }
            providers[config.id] = provider
            TBLog.log("  created provider for \(config.id), enabled=\(config.enabled)", category: "startup")
        }
        onStatusChange?()
    }

    // MARK: - Instance Management

    func addInstance(_ config: ProviderInstanceConfig) {
        TBLog.log("addInstance: id=\(config.id) enabled=\(config.enabled)", category: "mgr")
        instanceConfigs.append(config)
        sortConfigs()
        saveConfigs()

        if let provider = createProvider(for: config) {
            providers[config.id] = provider
            if shouldShowInMenuBar(config) {
                TBLog.log("  → firing visibility(true) for \(config.id)", category: "mgr")
                onProviderVisibilityChange?(config.id, true)
                refreshProvider(config.id)
            }
        }
    }

    func removeInstance(_ instanceId: String) {
        TBLog.log("removeInstance: id=\(instanceId)", category: "mgr")
        onProviderVisibilityChange?(instanceId, false)
        providers.removeValue(forKey: instanceId)
        snapshots.removeValue(forKey: instanceId)
        errors.removeValue(forKey: instanceId)
        loadingProviders.remove(instanceId)
        instanceConfigs.removeAll { $0.id == instanceId }
        saveConfigs()
    }

    func updateInstance(_ config: ProviderInstanceConfig) {
        guard let idx = instanceConfigs.firstIndex(where: { $0.id == config.id }) else {
            TBLog.log("updateInstance: id=\(config.id) NOT FOUND", category: "mgr")
            return
        }
        let oldConfig = instanceConfigs[idx]
        instanceConfigs[idx] = config
        saveConfigs()

        // Recreate provider with new config
        providers.removeValue(forKey: config.id)
        if let provider = createProvider(for: config) {
            providers[config.id] = provider
        }

        let wasVisible = shouldShowInMenuBar(oldConfig)
        let nowVisible = shouldShowInMenuBar(config)
        TBLog.log("updateInstance: id=\(config.id) wasVisible=\(wasVisible) nowVisible=\(nowVisible)", category: "mgr")

        if nowVisible && !wasVisible {
            TBLog.log("  → firing visibility(true) for \(config.id)", category: "mgr")
            onProviderVisibilityChange?(config.id, true)
            refreshProvider(config.id)
        } else if !nowVisible && wasVisible {
            TBLog.log("  → firing visibility(false) for \(config.id)", category: "mgr")
            onProviderVisibilityChange?(config.id, false)
        }
    }

    /// Called by the Toggle's `.onChange` — the Binding has already mutated
    /// `instanceConfigs`, so this only persists + fires side effects.
    func handleEnabledChanged(_ id: String, enabled: Bool) {
        TBLog.log("handleEnabledChanged: id=\(id) enabled=\(enabled)", category: "toggle")
        saveConfigs()

        if enabled {
            // Ensure provider instance exists
            if providers[id] == nil, let config = instanceConfigs.first(where: { $0.id == id }) {
                if let provider = createProvider(for: config) {
                    providers[id] = provider
                }
            }
            refreshProvider(id)
        }
        onStatusChange?()
    }

    func toggleProvider(_ id: String, enabled: Bool) {
        guard let idx = instanceConfigs.firstIndex(where: { $0.id == id }) else {
            TBLog.log("toggleProvider: id=\(id) NOT FOUND in instanceConfigs", category: "toggle")
            return
        }
        let oldConfig = instanceConfigs[idx]
        TBLog.log("toggleProvider: id=\(id) oldEnabled=\(oldConfig.enabled) newEnabled=\(enabled) (idx=\(idx))", category: "toggle")

        // Log ALL configs for context
        for (i, c) in instanceConfigs.enumerated() {
            TBLog.log("  config[\(i)]: id=\(c.id) enabled=\(c.enabled)\(i == idx ? " ← THIS ONE" : "")", category: "toggle")
        }

        instanceConfigs[idx].enabled = enabled
        saveConfigs()

        let wasVisible = shouldShowInMenuBar(oldConfig)
        let nowVisible = shouldShowInMenuBar(instanceConfigs[idx])

        if nowVisible && !wasVisible {
            TBLog.log("  → SHOW: firing visibility(true) for \(id)", category: "toggle")
            onProviderVisibilityChange?(id, true)
            refreshProvider(id)
        } else if !nowVisible && wasVisible {
            TBLog.log("  → HIDE: firing visibility(false) for \(id)", category: "toggle")
            onProviderVisibilityChange?(id, false)
        } else {
            TBLog.log("  → NO CHANGE: wasVisible=\(wasVisible) nowVisible=\(nowVisible)", category: "toggle")
        }
    }

    func provider(for id: String) -> (any UsageProvider)? {
        providers[id]
    }

    // MARK: - Polling

    func startPolling() {
        Task {
            await pollAllProviders()
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.pollAllProviders()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func restartPolling() {
        stopPolling()
        startPolling()
    }

    func setPollInterval(_ interval: TimeInterval) {
        pollInterval = interval
        defaults.set(interval, forKey: Self.pollIntervalKey)
        restartPolling()
    }

    func pollAllProviders() async {
        let enabledConfigs = await MainActor.run {
            instanceConfigs.filter(\.enabled)
        }

        // Mark trackable providers as loading (detectedOnly return instantly, no spinner needed)
        await MainActor.run {
            for config in enabledConfigs {
                let isTrackable = ProviderCatalog.type(for: config.typeId)?.category == .trackable
                if isTrackable, providers[config.id] != nil {
                    loadingProviders.insert(config.id)
                }
            }
            onStatusChange?()
        }

        // Poll all providers concurrently so slow ones don't block the rest
        await withTaskGroup(of: Void.self) { group in
            for config in enabledConfigs {
                guard let provider = providers[config.id] else { continue }
                let configId = config.id

                group.addTask {
                    do {
                        let snapshot = try await provider.fetchUsage()
                        await MainActor.run {
                            self.checkTokenRestoration(configId, newSnapshot: snapshot)
                            self.loadingProviders.remove(configId)
                            self.snapshots[configId] = snapshot
                            self.errors.removeValue(forKey: configId)
                            self.onStatusItemUpdate?(configId, snapshot)
                            self.onStatusChange?()
                        }
                    } catch {
                        let msg = error.localizedDescription
                        await MainActor.run {
                            self.loadingProviders.remove(configId)
                            self.errors[configId] = msg
                            self.onStatusItemUpdate?(configId, nil)
                            self.onStatusChange?()
                        }
                    }
                }
            }
        }
    }

    func refreshProvider(_ id: String) {
        guard let provider = providers[id] else { return }
        Task {
            await MainActor.run {
                self.loadingProviders.insert(id)
                self.onStatusItemUpdate?(id, self.snapshots[id])
                self.onStatusChange?()
            }

            do {
                let snapshot = try await provider.fetchUsage()
                await MainActor.run {
                    self.checkTokenRestoration(id, newSnapshot: snapshot)
                    self.loadingProviders.remove(id)
                    self.snapshots[id] = snapshot
                    self.errors.removeValue(forKey: id)
                    self.onStatusItemUpdate?(id, snapshot)
                    self.onStatusChange?()
                }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run {
                    self.loadingProviders.remove(id)
                    self.errors[id] = msg
                    self.onStatusItemUpdate?(id, nil)
                    self.onStatusChange?()
                }
            }
        }
    }

    /// Triggers confetti manually (for easter egg / testing).
    /// Pass a screen coordinate to burst from that location.
    func triggerConfetti(from screenPoint: CGPoint? = nil) {
        TBLog.log("triggerConfetti called, callback set=\(onTokensRestored != nil)", category: "confetti")
        onTokensRestored?("manual", screenPoint)
    }

    func refreshAvailability() {
        Task {
            let detected = ProviderCatalog.detectAll()
            await MainActor.run {
                self.detectedTypeIds = detected
            }
        }
    }

    // MARK: - Computed Helpers

    var sortedConfigs: [ProviderInstanceConfig] {
        instanceConfigs.sorted { a, b in
            let aTrackable = ProviderCatalog.type(for: a.typeId)?.category == .trackable
            let bTrackable = ProviderCatalog.type(for: b.typeId)?.category == .trackable
            if aTrackable != bTrackable { return aTrackable }
            return a.label < b.label
        }
    }

    var addableTypes: [ProviderTypeInfo] {
        let existingTypeIds = Set(instanceConfigs.map(\.typeId))
        return ProviderCatalog.allTypes.filter { typeInfo in
            typeInfo.supportsMultipleInstances || !existingTypeIds.contains(typeInfo.typeId)
        }
    }
}
