import Foundation
import Network
import CryptoKit
import AppKit

/// Handles OAuth PKCE flow for Claude Code credentials.
/// Opens browser → catches localhost callback → exchanges code for tokens → writes credentials.
class ClaudeOAuthAuthenticator {
    private static let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let authURL = "https://claude.ai/oauth/authorize"
    private static let tokenURL = "https://platform.claude.com/v1/oauth/token"

    private var listener: NWListener?
    private var port: UInt16 = 0
    private var codeVerifier: String = ""
    private var state: String = ""
    private var completion: ((Bool) -> Void)?

    static let credentialsPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/.credentials.json"
    }()

    func authenticate(completion: @escaping (Bool) -> Void) {
        self.completion = completion

        // Generate PKCE + state
        codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        state = generateState()

        // Start local HTTP server for callback
        guard startListener() else {
            TBLog.log("OAuth: failed to start listener", category: "oauth")
            completion(false)
            return
        }

        // Build authorization URL
        let redirectUri = "http://localhost:\(port)/callback"
        var components = URLComponents(string: Self.authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "scope", value: "user:profile user:inference user:sessions:claude_code user:mcp_servers org:create_api_key"),
            URLQueryItem(name: "state", value: state),
        ]

        guard let url = components.url else {
            TBLog.log("OAuth: failed to build auth URL", category: "oauth")
            completion(false)
            return
        }

        TBLog.log("OAuth: opening browser on port \(port)", category: "oauth")
        NSWorkspace.shared.open(url)
    }

    // MARK: - Local HTTP Server

    private func startListener() -> Bool {
        do {
            let params = NWParameters.tcp
            // Force IPv4 so localhost connections from the browser are received
            if let ipOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ipOptions.version = .v4
            }
            listener = try NWListener(using: params, on: .any)
        } catch {
            TBLog.log("OAuth: listener create failed: \(error)", category: "oauth")
            return false
        }

        guard let listener else { return false }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port {
                    self.port = port.rawValue
                    TBLog.log("OAuth: listening on port \(port.rawValue)", category: "oauth")
                }
            case .failed(let error):
                TBLog.log("OAuth: listener failed: \(error)", category: "oauth")
            default: break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: .global(qos: .userInitiated))

        // Wait for port assignment
        for _ in 0..<20 {
            if port != 0 { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }

        return port != 0
    }

    private func handleConnection(_ connection: NWConnection) {
        TBLog.log("OAuth: new connection received", category: "oauth")

        connection.stateUpdateHandler = { [weak self] state in
            TBLog.log("OAuth: connection state: \(state)", category: "oauth")
            switch state {
            case .ready:
                self?.receiveHTTP(on: connection)
            case .failed(let error):
                TBLog.log("OAuth: connection failed: \(error)", category: "oauth")
                connection.cancel()
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
    }

    private func receiveHTTP(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self else { return }

            if let error {
                TBLog.log("OAuth: receive error: \(error)", category: "oauth")
                connection.cancel()
                return
            }

            guard let data, let request = String(data: data, encoding: .utf8) else {
                TBLog.log("OAuth: no data or not UTF-8", category: "oauth")
                connection.cancel()
                return
            }

            TBLog.log("OAuth: received request: \(request.prefix(200))", category: "oauth")

            if let code = self.extractAuthCode(from: request) {
                TBLog.log("OAuth: received auth code", category: "oauth")
                let response = self.buildRedirectResponse()
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                self.stopListener()
                self.exchangeCodeForTokens(code: code)
            } else {
                TBLog.log("OAuth: no auth code in request", category: "oauth")
                let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func extractAuthCode(from request: String) -> String? {
        // Parse "GET /callback?code=xxx&state=yyy HTTP/1.1"
        guard let firstLine = request.split(separator: "\r\n").first,
              let urlPart = firstLine.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: String(urlPart)),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            return nil
        }
        // Verify state matches to prevent CSRF
        let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value
        guard returnedState == state else {
            TBLog.log("OAuth: state mismatch — possible CSRF", category: "oauth")
            return nil
        }
        return code
    }

    private func buildRedirectResponse() -> String {
        let location = "https://platform.claude.com/oauth/code/success?app=claude-code"
        return "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\n\r\n"
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(code: String) {
        let redirectUri = "http://localhost:\(port)/callback"

        guard let url = URL(string: Self.tokenURL) else {
            finish(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let bodyDict: [String: Any] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectUri,
            "client_id": Self.clientId,
            "code_verifier": codeVerifier,
            "state": state,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: bodyDict)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            let httpResponse = response as? HTTPURLResponse
            guard let data, let httpResponse, httpResponse.statusCode == 200 else {
                let code = httpResponse?.statusCode ?? 0
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
                TBLog.log("OAuth: token exchange failed: HTTP \(code) — \(body)", category: "oauth")
                self.finish(false)
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                TBLog.log("OAuth: invalid token response", category: "oauth")
                self.finish(false)
                return
            }

            let refreshToken = json["refresh_token"] as? String
            let expiresIn = json["expires_in"] as? Double ?? 86400

            self.writeCredentials(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresIn: expiresIn
            )

            TBLog.log("OAuth: authentication successful", category: "oauth")
            self.finish(true)
        }.resume()
    }

    // MARK: - Credentials

    private func writeCredentials(accessToken: String, refreshToken: String?, expiresIn: Double) {
        let path = Self.credentialsPath
        var creds: [String: Any] = [:]

        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            creds = existing
        }

        let expiresAt = (Date().timeIntervalSince1970 + expiresIn) * 1000

        var oauth: [String: Any] = [
            "accessToken": accessToken,
            "expiresAt": expiresAt,
            "scopes": "user:profile user:inference user:sessions:claude_code user:mcp_servers org:create_api_key",
        ]
        if let rt = refreshToken { oauth["refreshToken"] = rt }

        // Preserve subscription type if it existed
        if let existing = creds["claudeAiOauth"] as? [String: Any],
           let subType = existing["subscriptionType"] {
            oauth["subscriptionType"] = subType
        }

        creds["claudeAiOauth"] = oauth

        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        if let jsonData = try? JSONSerialization.data(withJSONObject: creds, options: [.prettyPrinted, .sortedKeys]) {
            try? jsonData.write(to: URL(fileURLWithPath: path))
            // Set permissions to 600
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    private func finish(_ success: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.completion?(success)
            self?.completion = nil
        }
    }

    // MARK: - PKCE & State

    private func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .prefix(128)
            .description
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
