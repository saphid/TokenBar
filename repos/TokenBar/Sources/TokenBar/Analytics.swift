import Foundation
import os

// MARK: - PostHog (HTTP API) + Axiom Analytics

enum Analytics {
    private static let logger = Logger(subsystem: "com.alexsouthwell.tokenbar", category: "analytics")

    static func setup() {
        PostHogClient.shared.capture("app_launched")
        AxiomLogger.shared.log(level: .info, message: "App launched", properties: ["event": "app_launch"])
        logger.info("Analytics initialized (PostHog HTTP + Axiom)")
    }

    static func track(_ event: String, properties: [String: Any] = [:]) {
        PostHogClient.shared.capture(event, properties: properties)
        AxiomLogger.shared.log(level: .info, message: event, properties: properties)
    }

    static func screen(_ name: String, properties: [String: Any] = [:]) {
        PostHogClient.shared.screen(name, properties: properties)
        AxiomLogger.shared.log(level: .info, message: "screen_view", properties: ["screen": name].merging(properties) { _, new in new })
    }

    static func identify(userId: String) {
        PostHogClient.shared.identify(userId)
    }
}

// MARK: - PostHog HTTP API Client

final class PostHogClient: @unchecked Sendable {
    static let shared = PostHogClient()

    private let apiKey = "POSTHOG_API_KEY_REDACTED"
    private let host = "https://us.i.posthog.com"
    private let session = URLSession(configuration: .ephemeral)
    private let queue = DispatchQueue(label: "com.alexsouthwell.tokenbar.posthog", qos: .utility)
    private let logger = Logger(subsystem: "com.alexsouthwell.tokenbar", category: "posthog")
    private var distinctId: String

    private init() {
        if let stored = UserDefaults.standard.string(forKey: "posthog.distinctId") {
            distinctId = stored
        } else {
            distinctId = UUID().uuidString
            UserDefaults.standard.set(distinctId, forKey: "posthog.distinctId")
        }
    }

    func identify(_ userId: String) {
        let oldId = distinctId
        distinctId = userId
        UserDefaults.standard.set(userId, forKey: "posthog.distinctId")
        send(event: "$identify", properties: ["$anon_distinct_id": oldId])
    }

    func capture(_ event: String, properties: [String: Any] = [:]) {
        send(event: event, properties: properties)
    }

    func screen(_ name: String, properties: [String: Any] = [:]) {
        var props = properties
        props["$screen_name"] = name
        send(event: "$screen", properties: props)
    }

    private func send(event: String, properties: [String: Any]) {
        queue.async { [self] in
            let body: [String: Any] = [
                "api_key": apiKey,
                "event": event,
                "distinct_id": distinctId,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "properties": defaultProperties().merging(properties) { _, new in new },
            ]

            guard let url = URL(string: "\(host)/capture/"),
                  let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData

            session.dataTask(with: request) { [weak self] _, response, error in
                if let error {
                    self?.logger.debug("PostHog error: \(error.localizedDescription)")
                }
            }.resume()
        }
    }

    private func defaultProperties() -> [String: Any] {
        [
            "$lib": "posthog-macos-http",
            "$lib_version": "1.0.0",
            "$os": "macOS",
            "$os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "$device_name": Host.current().localizedName ?? "Mac",
            "$app_name": "TokenBar",
            "$app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
        ]
    }
}

// MARK: - Axiom HTTP Ingest

final class AxiomLogger: @unchecked Sendable {
    static let shared = AxiomLogger()

    private let apiKey = "xaat-77f12dfb-c1a8-40ed-a44c-0cd94425087c"
    private let dataset = "token-bar-macos"
    private let endpoint = "https://api.axiom.co/v1/datasets"
    private let session = URLSession(configuration: .ephemeral)
    private let queue = DispatchQueue(label: "com.alexsouthwell.tokenbar.axiom", qos: .utility)
    private let logger = Logger(subsystem: "com.alexsouthwell.tokenbar", category: "axiom")

    enum Level: String {
        case debug, info, warn, error
    }

    func log(level: Level, message: String, properties: [String: Any] = [:]) {
        queue.async { [weak self] in
            self?.send(level: level, message: message, properties: properties)
        }
    }

    private func send(level: Level, message: String, properties: [String: Any]) {
        var payload: [String: Any] = [
            "_time": ISO8601DateFormatter().string(from: Date()),
            "level": level.rawValue,
            "message": message,
            "app": "token-bar-macos",
            "device": Host.current().localizedName ?? "Mac",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
        ]

        for (key, value) in properties {
            payload[key] = value
        }

        guard let url = URL(string: "\(endpoint)/\(dataset)/ingest") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: [payload])
            request.httpBody = jsonData
        } catch {
            logger.error("Axiom serialization error: \(error.localizedDescription)")
            return
        }

        session.dataTask(with: request) { [weak self] _, response, error in
            if let error {
                self?.logger.debug("Axiom ingest error: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                self?.logger.debug("Axiom ingest status: \(http.statusCode)")
            }
        }.resume()
    }
}
