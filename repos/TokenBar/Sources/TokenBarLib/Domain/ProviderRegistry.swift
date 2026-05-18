import Foundation

/// The category of a provider — determines auto-enable behavior and UI presentation.
enum ProviderCategory {
    case trackable       // Has live usage data (polled regularly)
    case detectedOnly    // Presence check only (installed but no live tracking)
}

/// A self-describing provider type. Each provider conforms to this protocol,
/// declaring its metadata, detection rules, icon sources, config fields, and factory.
///
/// This replaces the scattered metadata in ProviderCatalog static arrays,
/// the createProvider() switch in ProviderManager, and provider-specific
/// UI code in SettingsView.
protocol RegisteredProvider {
    /// Unique type identifier (e.g. "cursor", "openai", "chatgpt").
    static var typeId: String { get }

    /// Default display name for new instances (e.g. "Cursor", "OpenAI API").
    static var defaultName: String { get }

    /// SF Symbol name for fallback icon display.
    static var iconSymbol: String { get }

    /// URL to the provider's usage dashboard (opened via "Dashboard" link).
    static var dashboardURL: URL? { get }

    /// Whether this provider tracks live usage or just detects installation.
    static var category: ProviderCategory { get }

    /// Whether multiple instances can be configured (e.g. OpenAI personal + corporate).
    static var supportsMultipleInstances: Bool { get }

    /// Human-readable description of the data source, shown in the detail view.
    /// e.g. "~/.claude (OAuth)", "Cursor local database"
    static var dataSourceDescription: String? { get }

    /// How to detect whether the tool is installed locally.
    static var detection: DetectionSpec { get }

    /// How to resolve the provider's icon.
    static var iconSpec: IconSpec { get }

    /// Configuration fields the user needs to fill in. Empty = no config needed.
    static var configFields: [ConfigFieldDescriptor] { get }

    /// Factory method — creates a UsageProvider instance from configuration.
    static func create(instanceId: String, label: String, config: ProviderConfig) -> any UsageProvider
}

// MARK: - Defaults

extension RegisteredProvider {
    static var supportsMultipleInstances: Bool { false }
    static var dataSourceDescription: String? { nil }
    static var configFields: [ConfigFieldDescriptor] { [] }
}

// MARK: - Provider Registry

/// Central registry of all known provider types.
/// The ONE place to add a new provider: add its type to the `all` array.
enum ProviderRegistry {
    /// All registered provider types. Add new providers here.
    static let all: [any RegisteredProvider.Type] = [
        // Trackable (live usage data)
        CursorProviderDef.self,
        ClaudeCodeProviderDef.self,
        OpenAIProviderDef.self,
        GitHubCopilotProviderDef.self,
        CodexProviderDef.self,
        KiloCodeProviderDef.self,
        OpenCodeProviderDef.self,

        // Detection-only (presence check)
        ChatGPTProviderDef.self,
        WindsurfProviderDef.self,
        GeminiProviderDef.self,
        AiderProviderDef.self,
        OllamaProviderDef.self,
        ContinueProviderDef.self,
        ClineProviderDef.self,
        TabnineProviderDef.self,
        AmazonQProviderDef.self,
        CodyProviderDef.self,
        ZaiProviderDef.self,
        MinimaxProviderDef.self,
        OpenRouterProviderDef.self,
    ]

    /// Look up a registered provider type by its typeId.
    static func type(for typeId: String) -> (any RegisteredProvider.Type)? {
        all.first { $0.typeId == typeId }
    }

    /// Bridge for existing code that expects `ProviderTypeInfo` structs.
    /// Converts all registered providers to the legacy format.
    static func allTypeInfo() -> [ProviderTypeInfo] {
        all.map { provider in
            ProviderTypeInfo(
                typeId: provider.typeId,
                defaultName: provider.defaultName,
                iconSymbol: provider.iconSymbol,
                dashboardURL: provider.dashboardURL,
                category: provider.category == .trackable ? .trackable : .detectedOnly,
                supportsMultipleInstances: provider.supportsMultipleInstances,
                pathsToCheck: provider.detection.paths,
                commandsToCheck: provider.detection.commands,
                extensionPatterns: provider.detection.extensionPatterns
            )
        }
    }
}
