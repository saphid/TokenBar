import Foundation

/// Tracks OpenAI API spending for the current month via the organization costs endpoint.
///
/// Each instance can target a different account/org by using a separate API key
/// and optional Organization ID header. This enables corporate vs personal profiles.
struct OpenAIProvider: UsageProvider {
    let id: String
    let name: String
    let iconSymbol = "brain.head.profile"
    let dashboardURL: URL? = URL(string: "https://platform.openai.com/usage")

    private let keychainKey: String
    private let organizationId: String?
    private let budgetKey: String

    private static let costsURL = "https://api.openai.com/v1/organization/costs"

    /// Creates a new OpenAI provider instance.
    /// - Parameters:
    ///   - instanceId: Unique ID for this instance (e.g. "openai", "openai-corp")
    ///   - label: Display name (e.g. "OpenAI Personal", "OpenAI Corporate")
    ///   - keychainKey: Keychain key storing the API key
    ///   - organizationId: Optional OpenAI-Organization header value
    ///   - budgetKey: UserDefaults key for monthly budget
    init(
        instanceId: String = "openai",
        label: String = "OpenAI API",
        keychainKey: String = "openai_api_key",
        organizationId: String? = nil,
        budgetKey: String = "openai_budget"
    ) {
        self.id = instanceId
        self.name = label
        self.keychainKey = keychainKey
        self.organizationId = organizationId
        self.budgetKey = budgetKey
    }

    func isAvailable() async -> Bool {
        KeychainHelper.load(key: keychainKey) != nil
    }

    func fetchUsage() async throws -> UsageSnapshot {
        guard let apiKey = KeychainHelper.load(key: keychainKey), !apiKey.isEmpty else {
            throw ProviderError.authenticationRequired
        }

        let monthlyCost = try await fetchMonthlyCost(apiKey: apiKey)
        let budget = UserDefaults.standard.double(forKey: budgetKey)

        var quotas: [UsageQuota] = []

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
            quotas.append(UsageQuota(
                percentUsed: -1,
                label: "Monthly Spend",
                detailText: String(format: "$%.2f", monthlyCost),
                resetsAt: nextMonth,
                menuBarOverride: String(format: "$%.0f", monthlyCost)
            ))
        }

        return UsageSnapshot(
            providerId: id,
            quotas: quotas,
            capturedAt: Date(),
            accountTier: organizationId != nil ? "Org" : "API"
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
        if let orgId = organizationId, !orgId.isEmpty {
            request.setValue(orgId, forHTTPHeaderField: "OpenAI-Organization")
        }
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

// MARK: - RegisteredProvider Conformance

enum OpenAIProviderDef: RegisteredProvider {
    static let typeId = "openai"
    static let defaultName = "OpenAI API"
    static let iconSymbol = "brain.head.profile"
    static let dashboardURL: URL? = URL(string: "https://platform.openai.com/usage")
    static let category: ProviderCategory = .trackable
    static let supportsMultipleInstances: Bool = true
    static let dataSourceDescription: String? = "OpenAI API"

    static let detection = DetectionSpec()

    static let iconSpec = IconSpec(faviconDomain: "openai.com")

    static let configFields: [ConfigFieldDescriptor] = [
        ConfigFieldDescriptor(
            id: "keychainKey",
            label: "API Key",
            fieldType: .secureText,
            placeholder: "sk-...",
            helpText: "Get your key at platform.openai.com/api-keys",
            isRequired: true
        ),
        ConfigFieldDescriptor(
            id: "organizationId",
            label: "Organization ID",
            fieldType: .text,
            placeholder: "org-...",
            helpText: "Leave empty for default org"
        ),
        ConfigFieldDescriptor(
            id: "monthlyBudget",
            label: "Monthly Budget",
            fieldType: .currency,
            placeholder: "$",
            helpText: "Set to 0 or leave empty to show dollar amount instead of percentage"
        ),
    ]

    static func create(instanceId: String, label: String, config: ProviderConfig) -> any UsageProvider {
        let keychainKey = config.string("keychainKey") ?? "openai_api_key"
        let organizationId = config.string("organizationId")
        return OpenAIProvider(
            instanceId: instanceId,
            label: label,
            keychainKey: keychainKey,
            organizationId: organizationId,
            budgetKey: "openai_budget_\(instanceId)"
        )
    }
}
