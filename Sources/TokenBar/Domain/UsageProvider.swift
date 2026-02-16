import Foundation

protocol UsageProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var iconSymbol: String { get }   // SF Symbol name
    var dashboardURL: URL? { get }

    func isAvailable() async -> Bool
    func fetchUsage() async throws -> UsageSnapshot
}
