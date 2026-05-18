import Foundation

/// A provider that can only detect whether a tool is installed.
/// No live usage tracking — just shows as detected with a dashboard link.
struct DetectedProvider: UsageProvider {
    let id: String
    let name: String
    let iconSymbol: String
    let dashboardURL: URL?
    let isTrackable = false

    func isAvailable() async -> Bool {
        // Availability is determined by ProviderCatalog detection at startup.
        // Once created, a detected provider is always "available".
        true
    }

    func fetchUsage() async throws -> UsageSnapshot {
        UsageSnapshot(
            providerId: id,
            quotas: [UsageQuota(
                percentUsed: -1,
                label: "Installed",
                detailText: "Open dashboard to view usage",
                menuBarOverride: "--"
            )],
            capturedAt: Date(),
            accountTier: nil
        )
    }
}
