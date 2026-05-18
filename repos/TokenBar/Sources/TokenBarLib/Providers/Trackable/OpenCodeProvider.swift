import Foundation

/// Reads OpenCode's local storage to aggregate token usage and cost.
///
/// Data lives in ~/.local/share/opencode/storage/message/<sessionID>/<msgID>.json
/// Each assistant message contains: cost, tokens.{input, output, reasoning, cache.{read, write}}
/// Timestamps are in time.created (Unix ms).
struct OpenCodeProvider: UsageProvider {
    let id = "opencode"
    let name = "OpenCode"
    let iconSymbol = "terminal"
    let dashboardURL: URL? = nil

    private let storageDir: String

    static let defaultStorageDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/share/opencode/storage/message"
    }()

    init(storageDir: String? = nil) {
        self.storageDir = storageDir ?? Self.defaultStorageDir
    }

    func isAvailable() async -> Bool {
        FileManager.default.fileExists(atPath: storageDir)
    }

    func fetchUsage() async throws -> UsageSnapshot {
        guard FileManager.default.fileExists(atPath: storageDir) else {
            throw ProviderError.notAvailable
        }

        let stats = try aggregateUsage()

        var quotas: [UsageQuota] = []

        // Show today's token usage as the primary display
        if stats.todayTokens > 0 || stats.todayCost > 0 {
            let tokenText = Self.formatTokenCount(stats.todayTokens)
            if stats.todayCost > 0 {
                quotas.append(UsageQuota(
                    percentUsed: -1,
                    label: "Today",
                    detailText: "\(tokenText) tokens",
                    menuBarOverride: String(format: "$%.2f", stats.todayCost)
                ))
            } else {
                quotas.append(UsageQuota(
                    percentUsed: -1,
                    label: "Today",
                    detailText: nil,
                    menuBarOverride: tokenText
                ))
            }
        }

        // Show all-time stats
        let allTimeTokenText = Self.formatTokenCount(stats.allTimeTokens)
        if stats.allTimeCost > 0 {
            quotas.append(UsageQuota(
                percentUsed: -1,
                label: "All Time",
                detailText: "\(allTimeTokenText) tokens · \(stats.sessionCount) sessions",
                menuBarOverride: String(format: "$%.2f", stats.allTimeCost)
            ))
        } else {
            quotas.append(UsageQuota(
                percentUsed: -1,
                label: "All Time",
                detailText: "\(allTimeTokenText) tokens · \(stats.sessionCount) sessions"
            ))
        }

        guard !quotas.isEmpty else {
            throw ProviderError.parseFailed("No usage data found")
        }

        return UsageSnapshot(
            providerId: id,
            quotas: quotas,
            capturedAt: Date(),
            accountTier: nil
        )
    }

    // MARK: - Aggregation

    private struct UsageStats {
        var todayTokens: Int = 0
        var todayCost: Double = 0
        var allTimeTokens: Int = 0
        var allTimeCost: Double = 0
        var sessionCount: Int = 0
    }

    private func aggregateUsage() throws -> UsageStats {
        let fm = FileManager.default
        guard let sessionDirs = try? fm.contentsOfDirectory(atPath: storageDir) else {
            throw ProviderError.parseFailed("Cannot read OpenCode storage")
        }

        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let todayStartMs = Int(todayStart.timeIntervalSince1970 * 1000)

        var stats = UsageStats()
        stats.sessionCount = sessionDirs.count

        for sessionDir in sessionDirs {
            let sessionPath = (storageDir as NSString).appendingPathComponent(sessionDir)
            guard let msgFiles = try? fm.contentsOfDirectory(atPath: sessionPath) else { continue }

            for msgFile in msgFiles where msgFile.hasSuffix(".json") {
                let msgPath = (sessionPath as NSString).appendingPathComponent(msgFile)
                guard let data = fm.contents(atPath: msgPath),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                // Only count assistant messages (they have the token data)
                guard json["role"] as? String == "assistant" else { continue }
                guard let tokens = json["tokens"] as? [String: Any] else { continue }

                let input = tokens["input"] as? Int ?? 0
                let output = tokens["output"] as? Int ?? 0
                let reasoning = tokens["reasoning"] as? Int ?? 0
                let totalTokens = input + output + reasoning

                let cost = json["cost"] as? Double ?? 0

                stats.allTimeTokens += totalTokens
                stats.allTimeCost += cost

                // Check if this message is from today
                if let time = json["time"] as? [String: Any],
                   let created = time["created"] as? Int,
                   created >= todayStartMs {
                    stats.todayTokens += totalTokens
                    stats.todayCost += cost
                }
            }
        }

        return stats
    }

    // MARK: - Formatting

    static func formatTokenCount(_ count: Int) -> String {
        switch count {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return String(format: "%.1fK", Double(count) / 1_000)
        default: return String(format: "%.1fM", Double(count) / 1_000_000)
        }
    }
}

// MARK: - RegisteredProvider Conformance

enum OpenCodeProviderDef: RegisteredProvider {
    static let typeId = "opencode"
    static let defaultName = "OpenCode"
    static let iconSymbol = "rectangle.and.text.magnifyingglass"
    static let dashboardURL: URL? = nil
    static let category: ProviderCategory = .trackable
    static let dataSourceDescription: String? = "~/.local/share/opencode"

    static let detection = DetectionSpec(
        paths: ["~/.opencode", "~/.local/share/opencode"],
        commands: ["opencode"]
    )

    static let iconSpec = IconSpec(faviconDomain: "opencode.ai")

    static func create(instanceId: String, label: String, config: ProviderConfig) -> any UsageProvider {
        OpenCodeProvider()
    }
}
