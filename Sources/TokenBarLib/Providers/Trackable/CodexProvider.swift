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
    private let workspaceId: String?
    private let codexDir: String

    static let defaultCodexDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.codex"
    }()

    init(instanceId: String = "codex", label: String = "Codex", profile: String? = nil, orgId: String? = nil, workspaceId: String? = nil, codexDir: String? = nil) {
        self.id = instanceId
        self.name = label
        self.profile = profile
        self.orgId = orgId
        self.workspaceId = workspaceId
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

    // MARK: - Workspace UUID Cache
    //
    // The Codex app-server returns rate limits for whichever workspace the
    // auth token is scoped to. Workspace UUIDs are NOT the same as org IDs
    // and cannot be discovered via API. The only way to learn a workspace
    // UUID is to observe it in auth.json when the user happens to be on
    // that workspace.
    //
    // This cache persists org_id → workspace_uuid mappings in UserDefaults.
    // It updates on every fetch cycle by reading auth.json. Over time, as
    // the user naturally switches workspaces in any tool (CLI, Desktop,
    // ChatGPT, etc.), all workspace UUIDs get captured automatically.

    private static let workspaceCacheKey = "codexWorkspaceUUIDs"

    /// Returns the cached workspace UUID for an org, or nil if not yet discovered.
    static func cachedWorkspaceUUID(forOrgId orgId: String) -> String? {
        let cache = UserDefaults.standard.dictionary(forKey: workspaceCacheKey) as? [String: String] ?? [:]
        return cache[orgId]
    }

    /// Reads auth.json and updates the workspace UUID cache.
    /// The JWT id_token contains the org list; the access_token contains the
    /// current workspace UUID. We identify which org owns the current UUID by:
    ///   1. If there's only one org whose UUID we DON'T already know, and the
    ///      current UUID doesn't match any cached value, it must be that org's.
    ///   2. For the default org, we always know the UUID (it's the one present
    ///      at first launch).
    @discardableResult
    static func updateWorkspaceCache(codexDir: String? = nil) -> [String: String] {
        let dir = codexDir ?? defaultCodexDir
        guard let uuid = currentWorkspaceUUID(codexDir: dir) else { return [:] }

        let orgs = discoverOrganizations(codexDir: dir)
        guard !orgs.isEmpty else { return [:] }

        var cache = UserDefaults.standard.dictionary(forKey: workspaceCacheKey) as? [String: String] ?? [:]

        // If this UUID is already mapped, nothing to learn.
        if cache.values.contains(uuid) { return cache }

        // Find orgs that don't yet have a cached UUID.
        let unmappedOrgs = orgs.filter { cache[$0.id] == nil }

        if unmappedOrgs.count == 1 {
            // Only one unmapped org — this UUID must be theirs.
            cache[unmappedOrgs[0].id] = uuid
        } else if let defaultOrg = orgs.first(where: { $0.isDefault }) {
            // Multiple unmapped orgs. If we haven't seen the default org yet,
            // assume the current UUID belongs to it (auth.json starts on the
            // default workspace). Otherwise, we can't determine ownership.
            if cache[defaultOrg.id] == nil {
                cache[defaultOrg.id] = uuid
            } else {
                // All we know is this UUID isn't the default's. If there are
                // exactly 2 orgs total, we can deduce by elimination.
                let nonDefault = orgs.filter { !$0.isDefault }
                if nonDefault.count == 1 {
                    cache[nonDefault[0].id] = uuid
                }
            }
        }

        UserDefaults.standard.set(cache, forKey: workspaceCacheKey)
        return cache
    }

    func isAvailable() async -> Bool {
        FileManager.default.fileExists(atPath: codexDir)
    }

    func fetchUsage() async throws -> UsageSnapshot {
        // Update the workspace UUID cache from auth.json on every cycle.
        // This learns new workspace UUIDs as the user switches between
        // workspaces in any tool (CLI, Desktop, ChatGPT, etc.).
        Self.updateWorkspaceCache(codexDir: codexDir)

        // Try app-server RPC first (real-time data)
        if let snapshot = try? await fetchViaAppServer() {
            return snapshot
        }

        // Fall back to session JSONL parsing (stale but works offline).
        // Note: session files are org-agnostic so multi-org instances may
        // show the same data when the app-server is unavailable.
        return try fetchViaSessionFiles()
    }

    // MARK: - Helpers

    /// Derives a human-readable label from the window duration in minutes.
    private static func labelForWindowDuration(_ minutes: Int) -> String {
        switch minutes {
        case ...360:   return "\(minutes / 60)h Window"
        case ...1440:  return "Daily"
        case ...10080: return "Weekly"
        default:       return "Monthly"
        }
    }

    /// Parses a numeric percent value that may arrive as Int (app-server) or Double (session files).
    private static func parsePercent(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    /// Reads the access token from auth.json for chatgptAuthTokens login.
    private static func readAccessToken(codexDir: String) -> String? {
        let authPath = "\(codexDir)/auth.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String else {
            return nil
        }
        return accessToken
    }

    // MARK: - App-Server JSON-RPC

    private func fetchViaAppServer() async throws -> UsageSnapshot {
        let result = try await runAppServer()

        guard let rateLimits = result["rateLimits"] as? [String: Any] else {
            throw ProviderError.parseFailed("No rateLimits in app-server response")
        }

        var quotas: [UsageQuota] = []

        if let primary = rateLimits["primary"] as? [String: Any],
           let usedPercent = Self.parsePercent(primary["usedPercent"]) {
            let windowMins = primary["windowDurationMins"] as? Int
            let label = windowMins.map { Self.labelForWindowDuration($0) } ?? "Primary"
            let resetsAt: Date? = {
                guard let ts = primary["resetsAt"] as? Int else { return nil }
                return Date(timeIntervalSince1970: TimeInterval(ts))
            }()

            quotas.append(UsageQuota(
                percentUsed: usedPercent,
                label: label,
                detailText: "\(Int(usedPercent))% used",
                resetsAt: resetsAt
            ))
        }

        if let secondary = rateLimits["secondary"] as? [String: Any],
           let usedPercent = Self.parsePercent(secondary["usedPercent"]) {
            let windowMins = secondary["windowDurationMins"] as? Int
            let label = windowMins.map { Self.labelForWindowDuration($0) } ?? "Secondary"
            let resetsAt: Date? = {
                guard let ts = secondary["resetsAt"] as? Int else { return nil }
                return Date(timeIntervalSince1970: TimeInterval(ts))
            }()

            quotas.append(UsageQuota(
                percentUsed: usedPercent,
                label: label,
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
            let codexDir = self.codexDir
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.executeAppServerSync(
                        profile: self.profile,
                        orgId: self.orgId,
                        workspaceId: self.workspaceId,
                        codexDir: codexDir
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Reads the JWT from auth.json and returns the default org's ID, or nil.
    private static func defaultOrgId(codexDir: String) -> String? {
        discoverOrganizations(codexDir: codexDir)
            .first(where: { $0.isDefault })?
            .id
    }

    /// Reads the workspace UUID from the access_token JWT in auth.json.
    /// This UUID corresponds to the currently logged-in (default) workspace.
    static func currentWorkspaceUUID(codexDir: String? = nil) -> String? {
        let dir = codexDir ?? defaultCodexDir
        let authPath = "\(dir)/auth.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String else { return nil }

        let parts = accessToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var base64 = String(parts[1])
        while base64.count % 4 != 0 { base64 += "=" }

        guard let payloadData = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let accountId = auth["chatgpt_account_id"] as? String else { return nil }

        return accountId
    }

    private static func executeAppServerSync(profile: String?, orgId: String? = nil, workspaceId: String? = nil, codexDir: String) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        var args = ["codex", "-s", "read-only", "-a", "untrusted"]
        if let profile = profile {
            args += ["-p", profile]
        }
        args.append("app-server")
        process.arguments = args

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        try process.run()

        // Determine the login strategy:
        // - Default org (or no org specified): skip login; app-server auto-reads auth.json
        // - Non-default org with workspace UUID: use chatgptAuthTokens login
        // - Non-default org without workspace UUID: cannot fetch accurate data
        let isDefaultOrg: Bool
        if let orgId = orgId {
            isDefaultOrg = (orgId == defaultOrgId(codexDir: codexDir))
        } else {
            isDefaultOrg = true
        }

        // For non-default orgs, resolve the workspace identifier to use.
        // Preference: explicit config → cached UUID → org ID (fallback).
        // Workspace UUIDs give real data; org IDs create a "detached" session
        // that shows the correct plan type but may not reflect actual usage.
        let chatgptAccountId: String?
        if !isDefaultOrg {
            if let ws = workspaceId, !ws.isEmpty {
                chatgptAccountId = ws
            } else if let orgId = orgId, let cached = cachedWorkspaceUUID(forOrgId: orgId) {
                chatgptAccountId = cached
            } else {
                // Fall back to org ID. This creates a detached session that
                // returns the correct plan type but usage may not be accurate.
                // Once the workspace UUID is discovered (by the user switching
                // to this workspace in any Codex tool), the cache will be used.
                chatgptAccountId = orgId
            }
        } else {
            chatgptAccountId = nil
        }

        let needsLogin = chatgptAccountId != nil && readAccessToken(codexDir: codexDir) != nil
        let capsJson = needsLogin ? ",\"capabilities\":{\"experimentalApi\":true}" : ""
        let initMsg = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"TokenBar\",\"version\":\"1.0.0\"},\"protocolVersion\":\"2\"\(capsJson)}}\n"
        stdinPipe.fileHandleForWriting.write(initMsg.data(using: .utf8)!)

        Thread.sleep(forTimeInterval: 2)

        var rateLimitsId = 2
        if needsLogin, let wsId = chatgptAccountId, let accessToken = readAccessToken(codexDir: codexDir) {
            if let loginParams = try? JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": 10,
                "method": "account/login/start",
                "params": [
                    "type": "chatgptAuthTokens",
                    "accessToken": accessToken,
                    "chatgptAccountId": wsId
                ]
            ] as [String: Any]),
               let loginStr = String(data: loginParams, encoding: .utf8) {
                stdinPipe.fileHandleForWriting.write((loginStr + "\n").data(using: .utf8)!)
                Thread.sleep(forTimeInterval: 3)
            }
            rateLimitsId = 20
        }

        // Send rateLimits read
        let rlMsg = "{\"jsonrpc\":\"2.0\",\"id\":\(rateLimitsId),\"method\":\"account/rateLimits/read\",\"params\":{}}\n"
        stdinPipe.fileHandleForWriting.write(rlMsg.data(using: .utf8)!)

        Thread.sleep(forTimeInterval: 3)

        stdinPipe.fileHandleForWriting.closeFile()

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.terminate()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else {
            throw ProviderError.parseFailed("No output from app-server")
        }

        // Parse JSON-RPC responses. Check for the explicit rateLimits/read
        // response and any account/rateLimits/updated notifications.
        var explicitResult: [String: Any]?
        var notificationResult: [String: Any]?

        for line in output.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            if let responseId = json["id"] as? Int, responseId == rateLimitsId,
               let result = json["result"] as? [String: Any] {
                explicitResult = result
            }

            if json["method"] as? String == "account/rateLimits/updated",
               let params = json["params"] as? [String: Any] {
                notificationResult = params
            }
        }

        if let result = explicitResult { return result }
        if let result = notificationResult { return result }

        throw ProviderError.parseFailed("No rateLimits response from app-server")
    }

    // MARK: - Session JSONL Fallback

    private func fetchViaSessionFiles() throws -> UsageSnapshot {
        guard let rateLimits = findLatestRateLimits() else {
            throw ProviderError.parseFailed("No recent session data with rate limits found")
        }

        var quotas: [UsageQuota] = []

        if let primary = rateLimits["primary"] as? [String: Any],
           let usedPercent = Self.parsePercent(primary["used_percent"]) {
            let windowMins = primary["window_minutes"] as? Int
            let label = windowMins.map { Self.labelForWindowDuration($0) } ?? "Primary"
            let resetsAt: Date? = {
                guard let ts = primary["resets_at"] as? Int else { return nil }
                return Date(timeIntervalSince1970: TimeInterval(ts))
            }()
            quotas.append(UsageQuota(
                percentUsed: usedPercent,
                label: label,
                detailText: "\(Int(usedPercent))% used",
                resetsAt: resetsAt
            ))
        }

        if let secondary = rateLimits["secondary"] as? [String: Any],
           let usedPercent = Self.parsePercent(secondary["used_percent"]) {
            let windowMins = secondary["window_minutes"] as? Int
            let label = windowMins.map { Self.labelForWindowDuration($0) } ?? "Secondary"
            let resetsAt: Date? = {
                guard let ts = secondary["resets_at"] as? Int else { return nil }
                return Date(timeIntervalSince1970: TimeInterval(ts))
            }()
            quotas.append(UsageQuota(
                percentUsed: usedPercent,
                label: label,
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
        ConfigFieldDescriptor(
            id: "codexWorkspaceId",
            label: "Workspace UUID",
            fieldType: .text,
            placeholder: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
            helpText: "Required for non-default orgs. Find it by switching workspace in Codex Desktop, then running: codex debug app-server"
        ),
    ]

    static func create(instanceId: String, label: String, config: ProviderConfig) -> any UsageProvider {
        CodexProvider(
            instanceId: instanceId,
            label: label,
            profile: config.string("codexProfile"),
            orgId: config.string("codexOrgId"),
            workspaceId: config.string("codexWorkspaceId")
        )
    }
}
