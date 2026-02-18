import Foundation

/// Sub-protocol for providers that only detect installation — no live usage tracking.
/// Conforming types become ~15-line data declarations with no custom logic.
protocol DetectionOnlyProvider: RegisteredProvider {}

extension DetectionOnlyProvider {
    static var category: ProviderCategory { .detectedOnly }
    static var supportsMultipleInstances: Bool { false }
    static var configFields: [ConfigFieldDescriptor] { [] }
    static var dataSourceDescription: String? { "App detection only" }

    static func create(instanceId: String, label: String, config: ProviderConfig) -> any UsageProvider {
        DetectedProvider(
            id: instanceId,
            name: label,
            iconSymbol: iconSymbol,
            dashboardURL: dashboardURL
        )
    }
}
