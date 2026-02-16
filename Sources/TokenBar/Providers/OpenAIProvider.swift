import Foundation

/// Tracks OpenAI API spending for the current month via the organization costs endpoint.
///
/// Requires:
/// - An OpenAI API key stored in Keychain (key: "openai_api_key")
/// - The key must have organization read access (admin or reader role)
///
/// Optionally, the user sets a monthly budget in UserDefaults ("openai_budget").
/// If set, shows spend as percentage of budget. Otherwise shows dollar amount.
struct OpenAIProvider: UsageProvider {
    let id = "openai"
    let name = "OpenAI"
    let iconSymbol = "brain.head.profile"
    let dashboardURL: URL? = URL(string: "https://platform.openai.com/usage")

    private static let keychainKey = "openai_api_key"
    private static let budgetKey = "openai_budget"
    private static let costsURL = "https://api.openai.com/v1/organization/costs"

    func isAvailable() async -> Bool {
        KeychainHelper.load(key: Self.keychainKey) != nil
    }

    func fetchUsage() async throws -> UsageSnapshot {
        guard let apiKey = KeychainHelper.load(key: Self.keychainKey), !apiKey.isEmpty else {
            throw ProviderError.authenticationRequired
        }

        let monthlyCost = try await fetchMonthlyCost(apiKey: apiKey)
        let budget = UserDefaults.standard.double(forKey: Self.budgetKey)

        var quotas: [UsageQuota] = []

        // Calculate reset date (first of next month)
        let calendar = Calendar.current
        let now = Date()
        let nextMonth = calendar.date(byAdding: .month, value: 1,
            to: calendar.date(from: calendar.dateComponents([.year, .month], from: now))!)

        if budget > 0 {
            let percentUsed = min(100, (monthlyCost / budget) * 100)
            quotas.append(UsageQuota(
                percentUsed: percentUsed,
                label: "Monthly Budget",
                detailText: String(format: "$%.2f / $%.2f", monthlyCost, budget),
                resetsAt: nextMonth
            ))
        } else {
            // No budget set — show cost directly
            quotas.append(UsageQuota(
                percentUsed: -1,
                label: "Monthly Spend",
                detailText: String(format: "$%.2f", monthlyCost),
                resetsAt: nextMonth,
                menuBarOverride: String(format: "$%.0f", monthlyCost)
            ))
        }

        return UsageSnapshot(
            providerId: "openai",
            quotas: quotas,
            capturedAt: Date(),
            accountTier: "API"
        )
    }

    // MARK: - API

    private func fetchMonthlyCost(apiKey: String) async throws -> Double {
        let calendar = Calendar.current
        let now = Date()
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let startTimestamp = Int(startOfMonth.timeIntervalSince1970)

        guard let url = URL(string: "\(Self.costsURL)?start_time=\(startTimestamp)&bucket_width=1m&limit=1") else {
            throw ProviderError.executionFailed("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200: break
        case 401: throw ProviderError.authenticationRequired
        case 403: throw ProviderError.networkError("API key lacks organization access")
        case 429: throw ProviderError.networkError("Rate limited — try again later")
        default:  throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        return try Self.parseCostsResponse(data)
    }

    static func parseCostsResponse(_ data: Data) throws -> Double {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            throw ProviderError.parseFailed("Unexpected costs response format")
        }

        var totalCost: Double = 0

        for bucket in dataArray {
            guard let results = bucket["results"] as? [[String: Any]] else { continue }
            for result in results {
                if let amount = result["amount"] as? [String: Any],
                   let value = amount["value"] as? Double {
                    totalCost += value
                }
            }
        }

        return totalCost
    }
}
