import Foundation

protocol UsageProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var iconSymbol: String { get }   // SF Symbol name
    var dashboardURL: URL? { get }

    /// Whether this provider can fetch live usage data.
    /// Detection-only providers return false and are not auto-enabled in the menu bar.
    var isTrackable: Bool { get }

    func isAvailable() async -> Bool
    func fetchUsage() async throws -> UsageSnapshot
}

extension UsageProvider {
    var isTrackable: Bool { true }
}
