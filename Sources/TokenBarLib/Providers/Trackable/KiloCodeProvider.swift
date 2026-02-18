import Foundation

/// Reads Kilo Code's task data to aggregate token usage and cost.
///
/// Kilo Code (a Cline/Roo Code fork) stores per-task data in:
///   ~/Library/Application Support/{Cursor,Code}/User/globalStorage/kilocode.kilo-code/tasks/<UUID>/
///
/// Each task has ui_messages.json containing api_req_started entries with:
///   tokensIn, tokensOut, cacheReads, cacheWrites, cost
/// Timestamps are in the `ts` field (Unix ms).
struct KiloCodeProvider: UsageProvider {
    let id = "kilo-code"
    let name = "Kilo Code"
    let iconSymbol = "k.circle"
    let dashboardURL: URL? = URL(string: "https://kilocode.ai")

    private let tasksDirs: [String]

    /// Searches both Cursor and VS Code globalStorage for Kilo Code tasks.
    static let defaultTasksDirs: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Library/Application Support/Cursor/User/globalStorage/kilocode.kilo-code/tasks",
            "\(home)/Library/Application Support/Code/User/globalStorage/kilocode.kilo-code/tasks",
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0) }
    }()

    init(tasksDirs: [String]? = nil) {
        self.tasksDirs = tasksDirs ?? Self.defaultTasksDirs
    }

    func isAvailable() async -> Bool {
        !tasksDirs.isEmpty
    }

    func fetchUsage() async throws -> UsageSnapshot {
        guard !tasksDirs.isEmpty else {
            throw ProviderError.notAvailable
        }

        let stats = try aggregateUsage()

        var quotas: [UsageQuota] = []

        // Today's usage
        if stats.todayInputTokens > 0 || stats.todayOutputTokens > 0 {
            let totalToday = stats.todayInputTokens + stats.todayOutputTokens
            let tokenText = Self.formatTokenCount(totalToday)
            let detailParts = [
                "\(Self.formatTokenCount(stats.todayInputTokens)) in",
                "\(Self.formatTokenCount(stats.todayOutputTokens)) out",
            ]
            if stats.todayCost > 0 {
                quotas.append(UsageQuota(
                    percentUsed: -1,
                    label: "Today",
                    detailText: detailParts.joined(separator: " · "),
                    menuBarOverride: String(format: "$%.2f", stats.todayCost)
                ))
            } else {
                quotas.append(UsageQuota(
                    percentUsed: -1,
                    label: "Today",
                    detailText: detailParts.joined(separator: " · "),
                    menuBarOverride: tokenText
                ))
            }
        }

        // All-time usage
        let allTimeTotal = stats.allTimeInputTokens + stats.allTimeOutputTokens
        if allTimeTotal > 0 {
            let tokenText = Self.formatTokenCount(allTimeTotal)
            if stats.allTimeCost > 0 {
                quotas.append(UsageQuota(
                    percentUsed: -1,
                    label: "All Time",
                    detailText: "\(tokenText) tokens · \(stats.taskCount) tasks",
                    menuBarOverride: String(format: "$%.2f", stats.allTimeCost)
                ))
            } else {
                quotas.append(UsageQuota(
                    percentUsed: -1,
                    label: "All Time",
                    detailText: "\(tokenText) tokens · \(stats.taskCount) tasks"
                ))
            }
        }

        if quotas.isEmpty {
            quotas.append(UsageQuota(
                percentUsed: -1,
                label: "Usage",
                detailText: "\(stats.taskCount) tasks — no token data yet"
            ))
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
        var todayInputTokens: Int = 0
        var todayOutputTokens: Int = 0
        var todayCacheReads: Int = 0
        var todayCost: Double = 0
        var allTimeInputTokens: Int = 0
        var allTimeOutputTokens: Int = 0
        var allTimeCacheReads: Int = 0
        var allTimeCost: Double = 0
        var taskCount: Int = 0
    }

    private func aggregateUsage() throws -> UsageStats {
        let fm = FileManager.default
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let todayStartMs = Int(todayStart.timeIntervalSince1970 * 1000)

        var stats = UsageStats()

        for tasksDir in tasksDirs {
            guard let taskUUIDs = try? fm.contentsOfDirectory(atPath: tasksDir) else { continue }

            for taskUUID in taskUUIDs {
                let uiMessagesPath = (tasksDir as NSString)
                    .appendingPathComponent(taskUUID)
                    .appending("/ui_messages.json")
                guard let data = fm.contents(atPath: uiMessagesPath),
                      let messages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    continue
                }

                stats.taskCount += 1

                for msg in messages {
                    guard msg["say"] as? String == "api_req_started",
                          let text = msg["text"] as? String,
                          let reqData = try? JSONSerialization.jsonObject(
                              with: Data(text.utf8)
                          ) as? [String: Any] else {
                        continue
                    }

                    let tokensIn = reqData["tokensIn"] as? Int ?? 0
                    let tokensOut = reqData["tokensOut"] as? Int ?? 0
                    let cacheReads = reqData["cacheReads"] as? Int ?? 0
                    let cost = reqData["cost"] as? Double ?? 0

                    stats.allTimeInputTokens += tokensIn
                    stats.allTimeOutputTokens += tokensOut
                    stats.allTimeCacheReads += cacheReads
                    stats.allTimeCost += cost

                    // Check timestamp for today's usage
                    if let ts = msg["ts"] as? Int, ts >= todayStartMs {
                        stats.todayInputTokens += tokensIn
                        stats.todayOutputTokens += tokensOut
                        stats.todayCacheReads += cacheReads
                        stats.todayCost += cost
                    }
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

enum KiloCodeProviderDef: RegisteredProvider {
    static let typeId = "kilo-code"
    static let defaultName = "Kilo Code"
    static let iconSymbol = "k.circle"
    static let dashboardURL: URL? = URL(string: "https://kilocode.ai")
    static let category: ProviderCategory = .trackable
    static let dataSourceDescription: String? = "Kilo Code local task data"

    static let detection = DetectionSpec(
        paths: ["~/.kilocode"],
        commands: ["kilo", "kilocode"],
        extensionPatterns: ["kilocode.kilo-code-", "kilocode.Kilo-Code-"]
    )

    static let iconSpec = IconSpec(faviconDomain: "kilo.ai")

    static func create(instanceId: String, label: String, config: ProviderConfig) -> any UsageProvider {
        KiloCodeProvider()
    }
}
