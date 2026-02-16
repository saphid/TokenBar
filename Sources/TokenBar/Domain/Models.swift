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
