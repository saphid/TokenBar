import Foundation
import Combine

/// Manages provider registration, polling, and state.
/// All @Published properties are updated on the main thread.
class ProviderManager: ObservableObject {
    @Published var snapshots: [String: UsageSnapshot] = [:]
    @Published var errors: [String: String] = [:]
    @Published var availableProviderIds: [String] = []
    @Published var enabledProviderIds: Set<String>
    @Published var pollInterval: TimeInterval

    private var providers: [String: any UsageProvider] = [:]
    private var pollTimer: Timer?

    var onStatusItemUpdate: ((String, UsageSnapshot?) -> Void)?
    var onProviderVisibilityChange: ((String, Bool) -> Void)?

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "enabledProviders")
        enabledProviderIds = Set(saved ?? [])

        let savedInterval = UserDefaults.standard.double(forKey: "pollInterval")
        pollInterval = savedInterval > 0 ? savedInterval : 300
    }

    // MARK: - Provider Registration

    var allProviders: [(id: String, provider: any UsageProvider)] {
        providers.map { ($0.key, $0.value) }.sorted { $0.id < $1.id }
    }

    func registerProvider(_ provider: any UsageProvider) {
        providers[provider.id] = provider
    }

    func provider(for id: String) -> (any UsageProvider)? {
        providers[id]
    }

    // MARK: - Polling

    func startPolling() {
        Task {
            await checkAvailabilityAndPoll()
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
        UserDefaults.standard.set(interval, forKey: "pollInterval")
        restartPolling()
    }

    /// Re-check which providers are available (e.g. after adding an API key).
    func refreshAvailability() {
        Task {
            await checkAvailabilityAndPoll()
        }
    }

    private func checkAvailabilityAndPoll() async {
        var found: [String] = []
        for (id, provider) in providers {
            if await provider.isAvailable() {
                found.append(id)
            }
        }
        let available = found

        await MainActor.run {
            self.availableProviderIds = available

            // Auto-enable newly available providers
            for id in available where !self.enabledProviderIds.contains(id) {
                // Only auto-enable if this is the first run (empty set)
                // or if the provider was never explicitly disabled
                if UserDefaults.standard.stringArray(forKey: "enabledProviders") == nil {
                    self.enabledProviderIds.insert(id)
                }
            }
            // On first run, enable all
            if UserDefaults.standard.stringArray(forKey: "enabledProviders") == nil {
                self.enabledProviderIds = Set(available)
            }
            self.saveEnabledProviders()

            for id in available where self.enabledProviderIds.contains(id) {
                self.onProviderVisibilityChange?(id, true)
            }

            // Hide providers that are no longer available
            let currentlyShown = Set(self.enabledProviderIds)
            for id in currentlyShown where !available.contains(id) {
                self.onProviderVisibilityChange?(id, false)
            }
        }

        await pollAllProviders()
    }

    func pollAllProviders() async {
        let ids = await MainActor.run {
            Array(enabledProviderIds.intersection(Set(availableProviderIds)))
        }

        for id in ids {
            guard let provider = providers[id] else { continue }
            do {
                let snapshot = try await provider.fetchUsage()
                await MainActor.run {
                    self.snapshots[id] = snapshot
                    self.errors.removeValue(forKey: id)
                    self.onStatusItemUpdate?(id, snapshot)
                }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run {
                    self.errors[id] = msg
                    self.onStatusItemUpdate?(id, nil)
                }
            }
        }
    }

    func refreshProvider(_ id: String) {
        guard let provider = providers[id] else { return }
        Task {
            do {
                let snapshot = try await provider.fetchUsage()
                await MainActor.run {
                    self.snapshots[id] = snapshot
                    self.errors.removeValue(forKey: id)
                    self.onStatusItemUpdate?(id, snapshot)
                }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run {
                    self.errors[id] = msg
                    self.onStatusItemUpdate?(id, nil)
                }
            }
        }
    }

    func toggleProvider(_ id: String, enabled: Bool) {
        if enabled {
            enabledProviderIds.insert(id)
            onProviderVisibilityChange?(id, true)
            refreshProvider(id)
        } else {
            enabledProviderIds.remove(id)
            onProviderVisibilityChange?(id, false)
        }
        saveEnabledProviders()
    }

    private func saveEnabledProviders() {
        UserDefaults.standard.set(Array(enabledProviderIds), forKey: "enabledProviders")
    }
}
