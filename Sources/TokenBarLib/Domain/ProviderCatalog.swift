import AppKit
import Foundation

/// Describes a known provider type that can be instantiated.
struct ProviderTypeInfo: Identifiable {
    var id: String { typeId }
    let typeId: String
    let defaultName: String
    let iconSymbol: String
    let dashboardURL: URL?
    let category: Category
    let supportsMultipleInstances: Bool

    // Auto-detection paths
    let pathsToCheck: [String]
    let commandsToCheck: [String]
    let extensionPatterns: [String]  // glob prefixes for VS Code/Cursor/Windsurf extensions

    enum Category {
        case trackable
        case detectedOnly
    }
}

/// Central catalog for provider discovery, detection, and icon resolution.
/// Provider metadata is sourced from `ProviderRegistry`; this class handles
/// icon resolution and auto-detection using the registry's data.
enum ProviderCatalog {

    /// All known provider types — sourced from the provider registry.
    static var allTypes: [ProviderTypeInfo] {
        ProviderRegistry.allTypeInfo()
    }

    static func type(for typeId: String) -> ProviderTypeInfo? {
        allTypes.first { $0.typeId == typeId }
    }

    // MARK: - Icon Resolution

    /// In-memory cache so we only resolve each icon once per session.
    private static var iconCache: [String: NSImage] = [:]

    /// Returns the best available icon for a provider, checking (in order):
    /// 1. .app bundle icon (highest quality, instant)
    /// 2. VS Code/Cursor extension icon from package.json
    /// 3. Cached web icon (previously downloaded favicon)
    /// Returns nil only if no icon source is available yet.
    static func appIcon(for typeId: String) -> NSImage? {
        if let cached = iconCache[typeId] { return cached }

        if let icon = appBundleIcon(for: typeId) {
            iconCache[typeId] = icon
            return icon
        }
        if let icon = extensionIcon(for: typeId) {
            iconCache[typeId] = icon
            return icon
        }
        if let icon = cachedWebIcon(for: typeId) {
            iconCache[typeId] = icon
            return icon
        }
        return nil
    }

    /// Clear the in-memory cache (e.g., after downloading new web icons).
    static func clearIconCache() {
        iconCache.removeAll()
    }

    // MARK: Icon Source 1: .app bundle

    private static func appBundleIcon(for typeId: String) -> NSImage? {
        guard let registeredType = ProviderRegistry.type(for: typeId) else { return nil }
        let paths = registeredType.iconSpec.appBundlePaths
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return NSWorkspace.shared.icon(forFile: path)
            }
        }
        return nil
    }

    // MARK: Icon Source 2: VS Code / Cursor extension

    private static func extensionIcon(for typeId: String) -> NSImage? {
        guard let registeredType = ProviderRegistry.type(for: typeId) else { return nil }
        let patterns = registeredType.detection.extensionPatterns
        guard !patterns.isEmpty else { return nil }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let searchDirs = [
            "\(home)/.cursor/extensions",
            "\(home)/.vscode/extensions",
            "\(home)/.windsurf/extensions",
        ]
        for dir in searchDirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries {
                for pattern in patterns {
                    if entry.hasPrefix(pattern) {
                        let extPath = "\(dir)/\(entry)"
                        if let icon = loadExtensionIcon(at: extPath) {
                            return icon
                        }
                    }
                }
            }
        }
        return nil
    }

    /// Reads package.json → "icon" field and loads the referenced PNG.
    private static func loadExtensionIcon(at extensionPath: String) -> NSImage? {
        let packagePath = "\(extensionPath)/package.json"
        guard let data = FileManager.default.contents(atPath: packagePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let iconRelPath = json["icon"] as? String else {
            return nil
        }
        let iconPath = "\(extensionPath)/\(iconRelPath)"
        return NSImage(contentsOfFile: iconPath)
    }

    // MARK: Icon Source 3: Cached web icon

    private static var webIconCacheDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("TokenBar/icons")
    }

    private static func cachedWebIcon(for typeId: String) -> NSImage? {
        let path = webIconCacheDir.appendingPathComponent("\(typeId).png").path
        return NSImage(contentsOfFile: path)
    }

    /// Downloads favicons for any providers that don't have a local icon source.
    /// Call this once from startup — it fetches in the background and notifies on completion.
    static func downloadMissingIcons(completion: @escaping () -> Void) {
        let missing = allTypes.filter { appIcon(for: $0.typeId) == nil }
        guard !missing.isEmpty else { return }

        // Ensure cache directory exists
        try? FileManager.default.createDirectory(at: webIconCacheDir, withIntermediateDirectories: true)

        let group = DispatchGroup()
        var anyDownloaded = false

        for typeInfo in missing {
            group.enter()
            let tid = typeInfo.typeId

            // Read icon spec from registry
            guard let registeredType = ProviderRegistry.type(for: tid) else {
                group.leave()
                continue
            }
            let spec = registeredType.iconSpec

            // Build ordered list of URLs to try:
            // 1. Explicit overrides (e.g., GitHub org avatars)
            // 2. apple-touch-icon.png from provider domain (typically 180x180)
            // 3. Google favicon service (128px fallback)
            var urls: [URL] = spec.iconURLOverrides
            if let domain = spec.faviconDomain {
                urls.append(URL(string: "https://\(domain)/apple-touch-icon.png")!)
                urls.append(URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=128")!)
            }
            guard !urls.isEmpty else { group.leave(); continue }

            fetchFirstViableIcon(from: urls) { image in
                if let image {
                    saveWebIcon(image, typeId: tid)
                    anyDownloaded = true
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            if anyDownloaded {
                clearIconCache()
                completion()
            }
        }
    }

    /// Tries URLs in order, returning the first that yields a valid icon >= 32px.
    private static func fetchFirstViableIcon(from urls: [URL], completion: @escaping (NSImage?) -> Void) {
        guard let url = urls.first else { completion(nil); return }
        fetchIcon(from: url) { image in
            if let image {
                completion(image)
            } else {
                fetchFirstViableIcon(from: Array(urls.dropFirst()), completion: completion)
            }
        }
    }

    private static func fetchIcon(from url: URL, completion: @escaping (NSImage?) -> Void) {
        let task = URLSession.shared.dataTask(with: url) { data, response, _ in
            guard let data,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let image = NSImage(data: data),
                  image.isValid,
                  image.size.width >= 32 else {
                completion(nil)
                return
            }
            completion(image)
        }
        task.resume()
    }

    private static func saveWebIcon(_ image: NSImage, typeId: String) {
        let url = webIconCacheDir.appendingPathComponent("\(typeId).png")
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        TBLog.log("Downloaded web icon for \(typeId)", category: "icons")
    }

    // MARK: - Detection

    static func detect(_ typeInfo: ProviderTypeInfo) -> Bool {
        for path in typeInfo.pathsToCheck {
            let expanded = NSString(string: path).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                return true
            }
        }
        for command in typeInfo.commandsToCheck {
            if commandExists(command) {
                return true
            }
        }
        for pattern in typeInfo.extensionPatterns {
            if extensionInstalled(pattern: pattern) {
                return true
            }
        }
        return false
    }

    static func detectAll() -> Set<String> {
        var detected = Set<String>()
        for typeInfo in allTypes {
            if detect(typeInfo) {
                detected.insert(typeInfo.typeId)
            }
        }
        return detected
    }

    private static func commandExists(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func extensionInstalled(pattern: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let searchDirs = [
            "\(home)/.vscode/extensions",
            "\(home)/.cursor/extensions",
            "\(home)/.windsurf/extensions"
        ]
        for dir in searchDirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries {
                if entry.hasPrefix(pattern) {
                    return true
                }
            }
        }
        return false
    }
}
