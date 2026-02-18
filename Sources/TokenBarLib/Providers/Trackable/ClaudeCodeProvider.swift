import Foundation

/// Tracks Claude Code usage via the undocumented Anthropic OAuth usage API.
///
/// Calls GET https://api.anthropic.com/api/oauth/usage which returns real-time
/// utilization percentages for the 5-hour rolling window, 7-day ceiling, and
/// model-specific weekly caps. The OAuth token is read from ~/.claude/.credentials.json
/// (written by Claude Code itself).
///
/// If the token is expired, we refresh it using the OAuth refresh token before
/// making the API call. Refreshed tokens are written back to the credentials file.
struct ClaudeCodeProvider: UsageProvider {
    let id = "claude-code"
    let name = "Claude Code"
    let iconSymbol = "apple.terminal"
    let dashboardURL: URL? = URL(string: "https://console.anthropic.com/settings/billing")

    private let claudeDir: String
    private static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    private static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    private static let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    static let defaultClaudeDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude"
    }()

    init(claudeDir: String? = nil) {
        self.claudeDir = claudeDir ?? Self.defaultClaudeDir
    }

    func isAvailable() async -> Bool {
        readAccessToken() != nil
    }

    func fetchUsage() async throws -> UsageSnapshot {
        // Check if token is expired before making the API call
        let creds = readCredentials()
        guard var token = creds?.accessToken, !token.isEmpty else {
            throw ProviderError.authenticationRequired
        }

        // Proactively refresh if expired
        if let expiresAt = creds?.expiresAt, Date().timeIntervalSince1970 * 1000 > expiresAt {
            TBLog.log("Token expired, attempting refresh", category: "claude")
            if let refreshed = try? await refreshToken() {
                token = refreshed
            }
        }

        do {
            return try await fetchUsageWithToken(token)
        } catch let error as ProviderError where isAuthError(error) {
            // Token rejected — try refresh once
            TBLog.log("Got 401, attempting token refresh", category: "claude")
            guard let freshToken = try? await refreshToken() else {
                throw ProviderError.authenticationRequired
            }
            return try await fetchUsageWithToken(freshToken)
        }
    }

    // MARK: - API

    private func fetchUsageWithToken(_ token: String) async throws -> UsageSnapshot {
        guard let url = URL(string: Self.usageURL) else {
            throw ProviderError.executionFailed("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200: break
        case 401: throw ProviderError.authenticationRequired
        case 403: throw ProviderError.networkError("Insufficient permissions")
        default:  throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        return try Self.parseResponse(data)
    }

    // MARK: - Parsing

    static func parseResponse(_ data: Data) throws -> UsageSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.parseFailed("Response is not a JSON object")
        }

        var quotas: [UsageQuota] = []

        // 5-hour rolling window (primary — this is what rate-limits you)
        if let fiveHour = json["five_hour"] as? [String: Any],
           let utilization = fiveHour["utilization"] as? Double {
            quotas.append(UsageQuota(
                percentUsed: utilization,
                label: "5h Window",
                detailText: "\(Int(utilization))% used",
                resetsAt: parseResetDate(fiveHour["resets_at"])
            ))
        }

        // 7-day weekly ceiling
        if let sevenDay = json["seven_day"] as? [String: Any],
           let utilization = sevenDay["utilization"] as? Double {
            quotas.append(UsageQuota(
                percentUsed: utilization,
                label: "Weekly",
                detailText: "\(Int(utilization))% used",
                resetsAt: parseResetDate(sevenDay["resets_at"])
            ))
        }

        // Model-specific weekly caps (only show if non-zero)
        for (key, label) in [("seven_day_opus", "Opus Weekly"), ("seven_day_sonnet", "Sonnet Weekly")] {
            if let window = json[key] as? [String: Any],
               let utilization = window["utilization"] as? Double,
               utilization > 0 {
                quotas.append(UsageQuota(
                    percentUsed: utilization,
                    label: label,
                    detailText: "\(Int(utilization))% used",
                    resetsAt: parseResetDate(window["resets_at"])
                ))
            }
        }

        // Extra usage (credits) — API returns values in cents
        if let extra = json["extra_usage"] as? [String: Any],
           let isEnabled = extra["is_enabled"] as? Bool, isEnabled {
            let utilization = extra["utilization"] as? Double ?? 0
            let monthlyLimitCents = extra["monthly_limit"] as? Double
                ?? (extra["monthly_limit"] as? Int).map(Double.init)
            let usedCreditsCents = extra["used_credits"] as? Double ?? 0

            var detail = "\(Int(utilization))% used"
            if let limitCents = monthlyLimitCents {
                let usedDollars = usedCreditsCents / 100.0
                let limitDollars = limitCents / 100.0
                detail = String(format: "$%.2f / $%.2f", usedDollars, limitDollars)
            }

            quotas.append(UsageQuota(
                percentUsed: utilization,
                label: "Credits",
                detailText: detail,
                resetsAt: nil
            ))
        }

        guard !quotas.isEmpty else {
            throw ProviderError.parseFailed("No usage data in response")
        }

        // Read tier from credentials, or infer from API response shape
        let tier = readTierFromCredentials() ?? inferTier(from: json)

        return UsageSnapshot(
            providerId: "claude-code",
            quotas: quotas,
            capturedAt: Date(),
            accountTier: tier
        )
    }

    // MARK: - Token Refresh

    private func refreshToken() async throws -> String {
        guard let creds = readCredentials(),
              let refreshToken = creds.refreshToken, !refreshToken.isEmpty else {
            throw ProviderError.authenticationRequired
        }

        guard let url = URL(string: Self.tokenURL) else {
            throw ProviderError.executionFailed("Invalid token URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body = "grant_type=refresh_token&refresh_token=\(refreshToken)&client_id=\(Self.clientId)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            TBLog.log("Token refresh failed: HTTP \(code)", category: "claude")
            throw ProviderError.authenticationRequired
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = json["access_token"] as? String else {
            throw ProviderError.parseFailed("Invalid token refresh response")
        }

        // Write refreshed tokens back to credentials file
        let newRefreshToken = json["refresh_token"] as? String
        let expiresIn = json["expires_in"] as? Double
        writeRefreshedTokens(
            accessToken: newAccessToken,
            refreshToken: newRefreshToken,
            expiresIn: expiresIn
        )

        TBLog.log("Token refreshed successfully", category: "claude")
        return newAccessToken
    }

    private func writeRefreshedTokens(accessToken: String, refreshToken: String?, expiresIn: Double?) {
        let credPath = "\(claudeDir)/.credentials.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: credPath)),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = json["claudeAiOauth"] as? [String: Any] else {
            return
        }

        oauth["accessToken"] = accessToken
        if let rt = refreshToken { oauth["refreshToken"] = rt }
        if let exp = expiresIn {
            oauth["expiresAt"] = (Date().timeIntervalSince1970 + exp) * 1000
        }
        json["claudeAiOauth"] = oauth

        if let updated = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? updated.write(to: URL(fileURLWithPath: credPath))
        }
    }

    // MARK: - Credentials

    private struct OAuthCredentials {
        let accessToken: String?
        let refreshToken: String?
        let expiresAt: Double?
        let subscriptionType: String?
    }

    private func readCredentials() -> OAuthCredentials? {
        let credPath = "\(claudeDir)/.credentials.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: credPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any] else {
            return nil
        }
        return OAuthCredentials(
            accessToken: oauth["accessToken"] as? String,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: oauth["expiresAt"] as? Double,
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }

    private func readAccessToken() -> String? {
        guard let creds = readCredentials(),
              let token = creds.accessToken, !token.isEmpty else {
            return nil
        }
        return token
    }

    private static func readTierFromCredentials() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let credPath = "\(home)/.claude/.credentials.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: credPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any] else {
            return nil
        }
        return (oauth["subscriptionType"] as? String)?.uppercased()
    }

    /// Infers the subscription tier from the shape of the usage API response.
    /// Extra usage enabled → MAX, 5h + 7d windows → PRO, otherwise nil.
    private static func inferTier(from json: [String: Any]) -> String? {
        if let extra = json["extra_usage"] as? [String: Any],
           let isEnabled = extra["is_enabled"] as? Bool, isEnabled {
            return "MAX"
        }
        if json["five_hour"] != nil && json["seven_day"] != nil {
            return "PRO"
        }
        return nil
    }

    // MARK: - Helpers

    private static func parseResetDate(_ value: Any?) -> Date? {
        guard let str = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: str) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: str)
    }

    private func isAuthError(_ error: ProviderError) -> Bool {
        if case .authenticationRequired = error { return true }
        return false
    }
}

// MARK: - RegisteredProvider Conformance

enum ClaudeCodeProviderDef: RegisteredProvider {
    static let typeId = "claude-code"
    static let defaultName = "Claude Code"
    static let iconSymbol = "apple.terminal"
    static let dashboardURL: URL? = URL(string: "https://console.anthropic.com/settings/billing")
    static let category: ProviderCategory = .trackable
    static let dataSourceDescription: String? = "~/.claude (OAuth)"

    static let detection = DetectionSpec(
        paths: ["~/.claude"],
        commands: ["claude"]
    )

    static let iconSpec = IconSpec(
        appBundlePaths: ["/Applications/Claude.app"],
        faviconDomain: "anthropic.com"
    )

    static func create(instanceId: String, label: String, config: ProviderConfig) -> any UsageProvider {
        ClaudeCodeProvider()
    }
}
