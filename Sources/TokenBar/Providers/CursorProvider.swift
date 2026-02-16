import Foundation

/// Probes Cursor's local SQLite database for auth, then calls the usage-summary API.
///
/// Auth flow:
/// 1. Read access token from ~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
/// 2. Decode JWT to extract userId from the `sub` claim
/// 3. Build cookie: WorkosCursorSessionToken={userId}::{accessToken}
/// 4. GET https://cursor.com/api/usage-summary with that cookie
struct CursorProvider: UsageProvider {
    let id = "cursor"
    let name = "Cursor"
    let iconSymbol = "cursorarrow.rays"
    let dashboardURL: URL? = URL(string: "https://www.cursor.com/settings")

    private let dbPath: String

    static let defaultDatabasePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }()

    init(dbPath: String? = nil) {
        self.dbPath = dbPath ?? Self.defaultDatabasePath
    }

    func isAvailable() async -> Bool {
        FileManager.default.fileExists(atPath: dbPath)
    }

    func fetchUsage() async throws -> UsageSnapshot {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ProviderError.notAvailable
        }
        let accessToken = try readAccessToken()
        let userId = try Self.extractUserIdFromJWT(accessToken)
        let cookie = "WorkosCursorSessionToken=\(userId)::\(accessToken)"
        let data = try await fetchUsageSummary(cookie: cookie)
        return try Self.parseUsageSummary(data)
    }

    // MARK: - Token Extraction

    private func readAccessToken() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ProviderError.executionFailed("Failed to read Cursor database: \(error.localizedDescription)")
        }

        guard process.terminationStatus == 0 else {
            throw ProviderError.executionFailed("sqlite3 exited with status \(process.terminationStatus)")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !token.isEmpty else {
            throw ProviderError.authenticationRequired
        }
        return token
    }

    static func extractUserIdFromJWT(_ token: String) throws -> String {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else {
            throw ProviderError.parseFailed("Invalid JWT format")
        }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard let payloadData = Data(base64Encoded: base64) else {
            throw ProviderError.parseFailed("Failed to decode JWT payload")
        }

        guard let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let sub = json["sub"] as? String, !sub.isEmpty else {
            throw ProviderError.parseFailed("JWT payload missing 'sub' claim")
        }
        return sub
    }

    // MARK: - API Call

    private func fetchUsageSummary(cookie: String) async throws -> Data {
        guard let url = URL(string: "https://cursor.com/api/usage-summary") else {
            throw ProviderError.executionFailed("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200: return data
        case 401: throw ProviderError.sessionExpired
        case 403: throw ProviderError.authenticationRequired
        default:  throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }
    }

    // MARK: - Response Parsing

    static func parseUsageSummary(_ data: Data) throws -> UsageSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.parseFailed("Response is not a JSON object")
        }

        var quotas: [UsageQuota] = []
        let membershipType = json["membershipType"] as? String ?? "unknown"

        // Billing cycle reset date
        var resetsAt: Date?
        if let cycleEnd = json["billingCycleEnd"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetsAt = formatter.date(from: cycleEnd)
            if resetsAt == nil {
                formatter.formatOptions = [.withInternetDateTime]
                resetsAt = formatter.date(from: cycleEnd)
            }
        }

        let individualUsage = json["individualUsage"] as? [String: Any]

        // Plan usage (included requests)
        if let planUsage = individualUsage?["plan"] as? [String: Any],
           let enabled = planUsage["enabled"] as? Bool, enabled {
            let used = numericValue(from: planUsage, key: "used") ?? 0
            let limit = numericValue(from: planUsage, key: "limit") ?? 0

            if limit > 0 {
                let percentUsed = Double(used) / Double(limit) * 100
                quotas.append(UsageQuota(
                    percentUsed: min(100, max(0, percentUsed)),
                    label: "Monthly",
                    detailText: "\(used)/\(limit) requests",
                    resetsAt: resetsAt
                ))
            }
        }

        // On-demand usage
        if let onDemand = individualUsage?["onDemand"] as? [String: Any],
           let enabled = onDemand["enabled"] as? Bool, enabled {
            let used = numericValue(from: onDemand, key: "used") ?? 0
            let limit = numericValue(from: onDemand, key: "limit") ?? 0

            if limit > 0 {
                let percentUsed = Double(used) / Double(limit) * 100
                quotas.append(UsageQuota(
                    percentUsed: min(100, max(0, percentUsed)),
                    label: "On-Demand",
                    detailText: "\(used)/\(limit) on-demand",
                    resetsAt: resetsAt
                ))
            }
        }

        // Unlimited plans
        if let isUnlimited = json["isUnlimited"] as? Bool, isUnlimited {
            quotas.append(UsageQuota(
                percentUsed: 0,
                label: "Monthly",
                detailText: "Unlimited",
                resetsAt: nil
            ))
        }

        guard !quotas.isEmpty else {
            throw ProviderError.parseFailed("No usage data found in Cursor response")
        }

        return UsageSnapshot(
            providerId: "cursor",
            quotas: quotas,
            capturedAt: Date(),
            accountTier: membershipType.uppercased()
        )
    }

    private static func numericValue(from dict: [String: Any], key: String) -> Int? {
        if let intVal = dict[key] as? Int { return intVal }
        if let doubleVal = dict[key] as? Double { return Int(doubleVal) }
        return nil
    }
}
