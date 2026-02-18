import Foundation

/// Tracks OpenAI Codex CLI usage via the app-server JSON-RPC interface.
///
/// Spawns `codex -s read-only -a untrusted app-server` (optionally with `-p <profile>`)
/// and sends JSON-RPC calls to get real-time rate limit data. Falls back to parsing
/// session JSONL files if the app-server is unavailable.
///
/// Supports multiple instances with different config profiles, allowing separate
/// tracking for e.g. corporate and personal accounts.
struct CodexProvider: UsageProvider {
    let id: String
    let name: String
    let iconSymbol = "terminal"
    let dashboardURL: URL? = URL(string: "https://platform.openai.com/usage")

    private let profile: String?
    private let orgId: String?
    private let codexDir: String

    static let defaultCodexDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.codex"
    }()

    init(instanceId: String = "codex", label: String = "Codex", profile: String? = nil, orgId: String? = nil, codexDir: String? = nil) {
        self.id = instanceId
        self.name = label
        self.profile = profile
        self.orgId = orgId
        self.codexDir = codexDir ?? Self.defaultCodexDir
    }

    // MARK: - Organization Discovery

    /// An organization found in the Codex auth.json JWT.
    struct CodexOrganization {
        let id: String       // e.g. "org-mArd7ATirlXbS5miCvucSkSG"
        let title: String    // e.g. "Displayr" or "Personal"
        let isDefault: Bool
        let role: String     // e.g. "reader", "owner"
    }

    /// Reads `~/.codex/auth.json`, decodes the JWT id_token, and returns all
    /// organizations the user belongs to. Returns an empty array on any error.
    static func discoverOrganizations(codexDir: String? = nil) -> [CodexOrganization] {
        let dir = codexDir ?? defaultCodexDir
        let authPath = "\(dir)/auth.json"

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String else {
            return []
        }

        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return [] }

        var base64 = String(parts[1])
        while base64.count % 4 != 0 { base64 += "=" }

        guard let payloadData = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let orgs = auth["organizations"] as? [[String: Any]] else {
            return []
        }

        return orgs.compactMap { org in
            guard let id = org["id"] as? String,
                  let title = org["title"] as? String else { return nil }
            return CodexOrganization(
                id: id,
                title: title,
                isDefault: org["is_default"] as? Bool ?? false,
                role: org["role"] as? String ?? "unknown"
            )
        }
    }

    func isAvailable() async -> Bool {
        FileManager.default.fileExists(atPath: codexDir)
    }

    func fetchUsage() async throws -> UsageSnapshot {
        // Try app-server RPC first (real-time data)
        if let snapshot = try? await fetchViaAppServer() {
            return snapshot
        }

        // Fall back to session JSONL parsing (stale but works offline)
        return try fetchViaSessionFiles()
    }

    // MARK: - App-Server JSON-RPC

    private func fetchViaAppServer() async throws -> UsageSnapshot {
        let result = try await runAppServer()

        guard let rateLimits = result["rateLimits"] as? [String: Any] else {
            throw ProviderError.parseFailed("No rateLimits in app-server response")
        }

        var quotas: [UsageQuota] = []

        // Primary: 5-hour window
        if let primary = rateLimits["primary"] as? [String: Any],
           let usedPercent = primary["usedPercent"] as? Double {
            let resetsAt: Date? = {
                guard let ts = primary["resetsAt"] as? Int else { return nil }
                return Date(timeIntervalSince1970: TimeInterval(ts))
            }()

            quotas.append(UsageQuota(
                percentUsed: usedPercent,
                label: "5h Window",
                detailText: "\(Int(usedPercent))% used",
                resetsAt: resetsAt
            ))
        }

        // Secondary: weekly window
        if let secondary = rateLimits["secondary"] as? [String: Any],
           let usedPercent = secondary["usedPercent"] as? Double {
            let resetsAt: Date? = {
                guard let ts = secondary["resetsAt"] as? Int else { return nil }
                return Date(timeIntervalSince1970: TimeInterval(ts))
            }()

            quotas.append(UsageQuota(
                percentUsed: usedPercent,
                label: "Weekly",
                detailText: "\(Int(usedPercent))% used",
                resetsAt: resetsAt
            ))
        }

        // Credits
        if let credits = rateLimits["credits"] as? [String: Any] {
            let hasCredits = credits["hasCredits"] as? Bool ?? false
            let unlimited = credits["unlimited"] as? Bool ?? false
            let balance = credits["balance"] as? String

            if hasCredits || unlimited {
                let detail: String
                if unlimited {
                    detail = "Unlimited credits"
                } else if let bal = balance, !bal.isEmpty, bal != "0" {
                    detail = "$\(bal) remaining"
                } else {
                    detail = "Credits available"
                }
                quotas.append(UsageQuota(
                    percentUsed: -1,
                    label: "Credits",
                    detailText: detail
                ))
            }
        }

        guard !quotas.isEmpty else {
            throw ProviderError.parseFailed("No rate limit data from app-server")
        }

        let planType = (rateLimits["planType"] as? String)?.uppercased()

        return UsageSnapshot(
            providerId: id,
            quotas: quotas,
            capturedAt: Date(),
            accountTier: planType
        )
    }

    private func runAppServer() async throws -> [String: Any] {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.executeAppServerSync(profile: self.profile, orgId: self.orgId)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func executeAppServerSync(profile: String?, orgId: String? = nil) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        var args = ["codex", "-s", "read-only", "-a", "untrusted"]
        if let profile = profile {
            args += ["-p", profile]
        }
        if let orgId = orgId {
            args += ["-c", "org_id=\"\(orgId)\""]
        }
        args.append("app-server")
        process.arguments = args

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        try process.run()

        // Send initialize
        let initMsg = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"TokenBar\",\"version\":\"1.0.0\"}}}\n"
        stdinPipe.fileHandleForWriting.write(initMsg.data(using: .utf8)!)

        // Wait for initialize response
        Thread.sleep(forTimeInterval: 2)

        // Send rateLimits read
        let rlMsg = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"account/rateLimits/read\",\"params\":{}}\n"
        stdinPipe.fileHandleForWriting.write(rlMsg.data(using: .utf8)!)

        // Wait for response
        Thread.sleep(forTimeInterval: 3)

        // Close stdin to signal we're done
        stdinPipe.fileHandleForWriting.closeFile()

        // Read all output
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.terminate()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else {
            throw ProviderError.parseFailed("No output from app-server")
        }

        // Parse the JSON-RPC responses — find the rateLimits response (id: 2)
        for line in output.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let responseId = json["id"] as? Int, responseId == 2,
                  let result = json["result"] as? [String: Any] else { continue }
            return result
        }

        throw ProviderError.parseFailed("No rateLimits response from app-server")
    }

    // MARK: - Session JSONL Fallback

    private func fetchViaSessionFiles() throws -> UsageSnapshot {
        guard let rateLimits = findLatestRateLimits() else {
            throw ProviderError.parseFailed("No recent session data with rate limits found")
        }

        var quotas: [UsageQuota] = []

        if let primary = rateLimits["primary"] as? [String: Any],
           let usedPercent = primary["used_percent"] as? Double {
            let resetsAt: Date? = {
                guard let ts = primary["resets_at"] as? Int else { return nil }
                return Date(timeIntervalSince1970: TimeInterval(ts))
            }()
            quotas.append(UsageQuota(
                percentUsed: usedPercent,
                label: "5h Window",
                detailText: "\(Int(usedPercent))% used",
                resetsAt: resetsAt
            ))
        }

        if let secondary = rateLimits["secondary"] as? [String: Any],
           let usedPercent = secondary["used_percent"] as? Double {
            let resetsAt: Date? = {
                guard let ts = secondary["resets_at"] as? Int else { return nil }
                return Date(timeIntervalSince1970: TimeInterval(ts))
            }()
            quotas.append(UsageQuota(
                percentUsed: usedPercent,
                label: "Weekly",
                detailText: "\(Int(usedPercent))% used",
                resetsAt: resetsAt
            ))
        }

        if let credits = rateLimits["credits"] as? [String: Any] {
            let hasCredits = credits["has_credits"] as? Bool ?? false
            let unlimited = credits["unlimited"] as? Bool ?? false
            let balance = credits["balance"] as? String

            if hasCredits || unlimited {
                let detail: String
                if unlimited {
                    detail = "Unlimited credits"
                } else if let bal = balance, !bal.isEmpty, bal != "0" {
                    detail = "$\(bal) remaining"
                } else {
                    detail = "Credits available"
                }
                quotas.append(UsageQuota(
                    percentUsed: -1,
                    label: "Credits",
                    detailText: detail
                ))
            }
        }

        guard !quotas.isEmpty else {
            throw ProviderError.parseFailed("No rate limit data in session files")
        }

        let planType = readPlanType()

        return UsageSnapshot(
            providerId: id,
            quotas: quotas,
            capturedAt: Date(),
            accountTier: planType
        )
    }

    private func findLatestRateLimits() -> [String: Any]? {
        let searchDirs = [
            "\(codexDir)/sessions",
            "\(codexDir)/archived_sessions"
        ]

        var bestTimestamp: TimeInterval = 0
        var bestRateLimits: [String: Any]?

        for dir in searchDirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }

            let jsonlFiles = entries
                .filter { $0.hasSuffix(".jsonl") }
                .compactMap { filename -> (String, Date)? in
                    let path = "\(dir)/\(filename)"
                    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                          let modDate = attrs[.modificationDate] as? Date else { return nil }
                    return (path, modDate)
                }
                .sorted { $0.1 > $1.1 }

            for (path, _) in jsonlFiles.prefix(5) {
                if let rl = extractLastRateLimits(from: path) {
                    let ts = (rl["primary"] as? [String: Any])?["resets_at"] as? Int ?? 0
                    if TimeInterval(ts) > bestTimestamp {
                        bestTimestamp = TimeInterval(ts)
                        bestRateLimits = rl
                    }
                }
            }
        }

        return bestRateLimits
    }

    private func extractLastRateLimits(from path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let content = String(data: data, encoding: .utf8) else { return nil }

        let lines = content.split(separator: "\n")
        for line in lines.reversed() {
            guard line.contains("\"rate_limits\"") else { continue }
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            if let payload = json["payload"] as? [String: Any],
               let rl = payload["rate_limits"] as? [String: Any] {
                return rl
            }
        }

        return nil
    }

    // MARK: - Auth

    private func readPlanType() -> String? {
        let authPath = "\(codexDir)/auth.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let planType = json["plan_type"] as? String {
            return planType.uppercased()
        }

        if let tokens = json["tokens"] as? [String: Any],
           let idToken = tokens["id_token"] as? String {
            let parts = idToken.split(separator: ".")
            if parts.count >= 2 {
                var base64 = String(parts[1])
                while base64.count % 4 != 0 { base64 += "=" }
                if let payloadData = Data(base64Encoded: base64),
                   let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                   let plan = claims["chatgpt_plan_type"] as? String {
                    return plan.uppercased()
                }
            }
        }

        return nil
    }
}

// MARK: - RegisteredProvider Conformance

enum CodexProviderDef: RegisteredProvider {
    static let typeId = "codex"
    static let defaultName = "Codex"
    static let iconSymbol = "terminal"
    static let dashboardURL: URL? = URL(string: "https://platform.openai.com/usage")
    static let category: ProviderCategory = .trackable
    static let supportsMultipleInstances: Bool = true
    static let dataSourceDescription: String? = "~/.codex"

    static let detection = DetectionSpec(
        paths: ["/Applications/Codex.app"],
        commands: ["codex"]
    )

    static let iconSpec = IconSpec(
        appBundlePaths: ["/Applications/Codex.app"],
        faviconDomain: "openai.com"
    )

    static let configFields: [ConfigFieldDescriptor] = [
        ConfigFieldDescriptor(
            id: "codexProfile",
            label: "Config Profile",
            fieldType: .text,
            placeholder: "default",
            helpText: "Profile from config.toml (e.g. work, personal)"
        ),
        ConfigFieldDescriptor(
            id: "codexOrgId",
            label: "Organization ID",
            fieldType: .text,
            placeholder: "org-...",
            helpText: "OpenAI organization ID for this Codex instance"
        ),
    ]

    static func create(instanceId: String, label: String, config: ProviderConfig) -> any UsageProvider {
        CodexProvider(
            instanceId: instanceId,
            label: label,
            profile: config.string("codexProfile"),
            orgId: config.string("codexOrgId")
        )
    }
}
