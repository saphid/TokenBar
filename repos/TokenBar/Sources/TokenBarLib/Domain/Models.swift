import AppKit
import Foundation

struct UsageSnapshot: Sendable {
    let providerId: String
    let quotas: [UsageQuota]
    let capturedAt: Date
    let accountTier: String?
}

struct UsageQuota: Sendable {
    let percentUsed: Double       // 0-100, or -1 if not applicable
    let label: String             // "Monthly", "On-Demand", "Daily", etc.
    let detailText: String?       // "326/40000 requests" or "$4.23 / $100.00"
    let resetsAt: Date?
    let menuBarOverride: String?  // If set, show this in menu bar instead of "XX%"

    init(
        percentUsed: Double,
        label: String,
        detailText: String? = nil,
        resetsAt: Date? = nil,
        menuBarOverride: String? = nil
    ) {
        self.percentUsed = percentUsed
        self.label = label
        self.detailText = detailText
        self.resetsAt = resetsAt
        self.menuBarOverride = menuBarOverride
    }

    var percentRemaining: Double { max(0, 100 - percentUsed) }

    var statusColor: StatusColor {
        guard percentUsed >= 0 else { return .unknown }
        switch percentUsed {
        case ..<50: return .good
        case ..<80: return .warning
        default: return .critical
        }
    }
}

enum StatusColor {
    case good, warning, critical, unknown
}

enum ProviderError: Error, LocalizedError {
    case notAvailable
    case authenticationRequired
    case sessionExpired
    case parseFailed(String)
    case networkError(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable: return "Provider not available"
        case .authenticationRequired: return "Authentication required"
        case .sessionExpired: return "Session expired — please re-authenticate"
        case .parseFailed(let msg): return "Parse error: \(msg)"
        case .networkError(let msg): return "Network error: \(msg)"
        case .executionFailed(let msg): return "Execution failed: \(msg)"
        }
    }
}

// MARK: - Appearance Mode

enum AppearanceMode: String, Codable, CaseIterable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Sort Mode

enum SortMode: String, Codable, CaseIterable {
    case manual              // user-defined order via drag/reorder
    case mostAvailableNow    // sort by most constraining quota (can I use it now?)
    case mostAvailableLong   // sort by longest-term quota (monthly headroom)
    case resetTime           // sort by resetsAt (soonest reset first)
    case alphabetical        // sort by label A-Z

    var displayName: String {
        switch self {
        case .manual: return "Manual"
        case .mostAvailableNow: return "Most Available Now"
        case .mostAvailableLong: return "Most Available (Monthly)"
        case .resetTime: return "Reset Time"
        case .alphabetical: return "Alphabetical"
        }
    }
}

// MARK: - Provider Instance Configuration (persisted)

/// A configured instance of a provider type. Stored in UserDefaults.
/// Provider-specific settings live in `providerConfig` — a generic dictionary
/// keyed by field IDs declared in `RegisteredProvider.configFields`.
struct ProviderInstanceConfig: Codable, Identifiable, Equatable {
    var id: String          // unique instance ID, e.g. "cursor", "openai-corp", "claude-code"
    var typeId: String      // references ProviderRegistry type
    var label: String       // user-visible name
    var enabled: Bool
    var isAutoDetected: Bool
    var sortOrder: Int?     // manual sort position (only used when sortMode == .manual)

    /// Generic provider-specific configuration. Keys match ConfigFieldDescriptor.id.
    var providerConfig: [String: AnyCodableValue]

    // Equatable auto-synthesized by Swift — compares ALL fields including providerConfig.
    // This is critical: SwiftUI's ForEach uses Equatable to decide
    // whether to re-render a row. If we only compared `id`, toggling
    // `enabled` wouldn't trigger a UI update.

    init(
        id: String,
        typeId: String,
        label: String,
        enabled: Bool,
        isAutoDetected: Bool,
        sortOrder: Int? = nil,
        providerConfig: [String: AnyCodableValue] = [:]
    ) {
        self.id = id
        self.typeId = typeId
        self.label = label
        self.enabled = enabled
        self.isAutoDetected = isAutoDetected
        self.sortOrder = sortOrder
        self.providerConfig = providerConfig
    }

    // MARK: Backward-compatible convenience init (bridges old call sites)

    init(
        id: String,
        typeId: String,
        label: String,
        enabled: Bool,
        isAutoDetected: Bool,
        sortOrder: Int? = nil,
        keychainKey: String? = nil,
        organizationId: String? = nil,
        monthlyBudget: Double? = nil,
        codexProfile: String? = nil,
        codexOrgId: String? = nil
    ) {
        self.id = id
        self.typeId = typeId
        self.label = label
        self.enabled = enabled
        self.isAutoDetected = isAutoDetected
        self.sortOrder = sortOrder

        var config: [String: AnyCodableValue] = [:]
        if let v = keychainKey { config["keychainKey"] = .string(v) }
        if let v = organizationId { config["organizationId"] = .string(v) }
        if let v = monthlyBudget { config["monthlyBudget"] = .double(v) }
        if let v = codexProfile { config["codexProfile"] = .string(v) }
        if let v = codexOrgId { config["codexOrgId"] = .string(v) }
        self.providerConfig = config
    }

    // MARK: Computed shims for old field names (used during transition)

    var keychainKey: String? {
        get { providerConfig["keychainKey"]?.stringValue }
        set {
            providerConfig["keychainKey"] = newValue.map { .string($0) }
        }
    }

    var organizationId: String? {
        get { providerConfig["organizationId"]?.stringValue }
        set {
            providerConfig["organizationId"] = newValue.map { .string($0) }
        }
    }

    var monthlyBudget: Double? {
        get { providerConfig["monthlyBudget"]?.doubleValue }
        set {
            providerConfig["monthlyBudget"] = newValue.map { .double($0) }
        }
    }

    var codexProfile: String? {
        get { providerConfig["codexProfile"]?.stringValue }
        set {
            providerConfig["codexProfile"] = newValue.map { .string($0) }
        }
    }

    var codexOrgId: String? {
        get { providerConfig["codexOrgId"]?.stringValue }
        set {
            providerConfig["codexOrgId"] = newValue.map { .string($0) }
        }
    }

    // MARK: Codable — backward-compatible decoder

    private enum CodingKeys: String, CodingKey {
        case id, typeId, label, enabled, isAutoDetected, sortOrder, providerConfig
        // Legacy keys (read during migration, never written)
        case keychainKey, organizationId, monthlyBudget, codexProfile, codexOrgId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        typeId = try c.decode(String.self, forKey: .typeId)
        label = try c.decode(String.self, forKey: .label)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        isAutoDetected = try c.decode(Bool.self, forKey: .isAutoDetected)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder)

        // Try new format first
        if let config = try? c.decode([String: AnyCodableValue].self, forKey: .providerConfig) {
            providerConfig = config
        } else {
            // Migrate from old typed fields
            var config: [String: AnyCodableValue] = [:]
            if let v = try c.decodeIfPresent(String.self, forKey: .keychainKey) {
                config["keychainKey"] = .string(v)
            }
            if let v = try c.decodeIfPresent(String.self, forKey: .organizationId) {
                config["organizationId"] = .string(v)
            }
            if let v = try c.decodeIfPresent(Double.self, forKey: .monthlyBudget) {
                config["monthlyBudget"] = .double(v)
            }
            if let v = try c.decodeIfPresent(String.self, forKey: .codexProfile) {
                config["codexProfile"] = .string(v)
            }
            if let v = try c.decodeIfPresent(String.self, forKey: .codexOrgId) {
                config["codexOrgId"] = .string(v)
            }
            providerConfig = config
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(typeId, forKey: .typeId)
        try c.encode(label, forKey: .label)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(isAutoDetected, forKey: .isAutoDetected)
        try c.encodeIfPresent(sortOrder, forKey: .sortOrder)
        try c.encode(providerConfig, forKey: .providerConfig)
    }

    /// Returns a `ProviderConfig` wrapper for use with `RegisteredProvider.create()`.
    var asProviderConfig: ProviderConfig {
        ProviderConfig(providerConfig)
    }
}
