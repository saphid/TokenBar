import Foundation

/// Tracks GitHub Copilot quota via the internal user API.
///
/// Uses `gh auth token` for authentication, then calls
/// GET https://api.github.com/copilot_internal/user
/// which returns quota snapshots for chat, completions, and premium interactions.
///
/// Note: This is an undocumented internal API used by VS Code, JetBrains, and Zed.
/// It could change without notice but is currently the only way to get individual quota data.
struct GitHubCopilotProvider: UsageProvider {
    let id = "github-copilot"
    let name = "GitHub Copilot"
    let iconSymbol = "chevron.left.forwardslash.chevron.right"
    let dashboardURL: URL? = URL(string: "https://github.com/settings/copilot")

    private static let apiURL = "https://api.github.com/copilot_internal/user"

    func isAvailable() async -> Bool {
        // Check if gh CLI is available and authenticated
        let token = try? getGHToken()
        return token != nil && !token!.isEmpty
    }

    func fetchUsage() async throws -> UsageSnapshot {
        let token = try getGHToken()
        let data = try await fetchCopilotUser(token: token)
        return try Self.parseResponse(data)
    }

    // MARK: - Auth

    private func getGHToken() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh", "auth", "token"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ProviderError.executionFailed("Failed to run gh auth token: \(error.localizedDescription)")
        }

        guard process.terminationStatus == 0 else {
            throw ProviderError.authenticationRequired
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !token.isEmpty else {
            throw ProviderError.authenticationRequired
        }
        return token
    }

    // MARK: - API

    private func fetchCopilotUser(token: String) async throws -> Data {
        guard let url = URL(string: Self.apiURL) else {
            throw ProviderError.executionFailed("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200: return data
        case 401: throw ProviderError.authenticationRequired
        case 403: throw ProviderError.networkError("Copilot not enabled or insufficient permissions")
        case 404: throw ProviderError.networkError("Copilot not available for this account")
        default:  throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }
    }

    // MARK: - Parsing

    static func parseResponse(_ data: Data) throws -> UsageSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.parseFailed("Response is not a JSON object")
        }

        guard let quotaSnapshots = json["quota_snapshots"] as? [String: Any] else {
            throw ProviderError.parseFailed("No quota_snapshots in response")
        }

        let plan = json["copilot_plan"] as? String ?? "unknown"

        // Parse reset date
        var resetsAt: Date?
        if let resetStr = json["quota_reset_date_utc"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetsAt = formatter.date(from: resetStr)
            if resetsAt == nil {
                formatter.formatOptions = [.withInternetDateTime]
                resetsAt = formatter.date(from: resetStr)
            }
        }

        var quotas: [UsageQuota] = []

        // Premium interactions (the one with actual limits for most plans)
        if let premium = quotaSnapshots["premium_interactions"] as? [String: Any] {
            let unlimited = premium["unlimited"] as? Bool ?? false

            if unlimited {
                quotas.append(UsageQuota(
                    percentUsed: 0,
                    label: "Premium",
                    detailText: "Unlimited premium requests",
                    resetsAt: resetsAt
                ))
            } else {
                let entitlement = premium["entitlement"] as? Int ?? 0
                let remaining = premium["remaining"] as? Int ?? 0
                let percentRemaining = premium["percent_remaining"] as? Double ?? 100.0
                let percentUsed = max(0, min(100, 100.0 - percentRemaining))
                let used = entitlement - remaining

                quotas.append(UsageQuota(
                    percentUsed: percentUsed,
                    label: "Premium",
                    detailText: "\(used)/\(entitlement) premium requests used",
                    resetsAt: resetsAt
                ))
            }
        }

        // Chat quota
        if let chat = quotaSnapshots["chat"] as? [String: Any] {
            let unlimited = chat["unlimited"] as? Bool ?? false
            if !unlimited {
                let entitlement = chat["entitlement"] as? Int ?? 0
                let remaining = chat["remaining"] as? Int ?? 0
                let percentRemaining = chat["percent_remaining"] as? Double ?? 100.0
                let percentUsed = max(0, min(100, 100.0 - percentRemaining))
                let used = entitlement - remaining

                quotas.append(UsageQuota(
                    percentUsed: percentUsed,
                    label: "Chat",
                    detailText: "\(used)/\(entitlement) chat messages",
                    resetsAt: resetsAt
                ))
            }
        }

        // Completions quota
        if let completions = quotaSnapshots["completions"] as? [String: Any] {
            let unlimited = completions["unlimited"] as? Bool ?? false
            if !unlimited {
                let entitlement = completions["entitlement"] as? Int ?? 0
                let remaining = completions["remaining"] as? Int ?? 0
                let percentRemaining = completions["percent_remaining"] as? Double ?? 100.0
                let percentUsed = max(0, min(100, 100.0 - percentRemaining))
                let used = entitlement - remaining

                quotas.append(UsageQuota(
                    percentUsed: percentUsed,
                    label: "Completions",
                    detailText: "\(used)/\(entitlement) completions",
                    resetsAt: resetsAt
                ))
            }
        }

        if quotas.isEmpty {
            // All unlimited — show a single "unlimited" quota
            quotas.append(UsageQuota(
                percentUsed: 0,
                label: "Usage",
                detailText: "All quotas unlimited",
                resetsAt: nil
            ))
        }

        return UsageSnapshot(
            providerId: "github-copilot",
            quotas: quotas,
            capturedAt: Date(),
            accountTier: plan.uppercased()
        )
    }
}

// MARK: - RegisteredProvider Conformance

enum GitHubCopilotProviderDef: RegisteredProvider {
    static let typeId = "github-copilot"
    static let defaultName = "GitHub Copilot"
    static let iconSymbol = "chevron.left.forwardslash.chevron.right"
    static let dashboardURL: URL? = URL(string: "https://github.com/settings/copilot")
    static let category: ProviderCategory = .trackable
    static let dataSourceDescription: String? = "~/.config/github-copilot"

    static let detection = DetectionSpec(
        paths: ["~/.config/github-copilot"],
        extensionPatterns: ["github.copilot-"]
    )

    static let iconSpec = IconSpec(faviconDomain: "github.com")

    static func create(instanceId: String, label: String, config: ProviderConfig) -> any UsageProvider {
        GitHubCopilotProvider()
    }
}
