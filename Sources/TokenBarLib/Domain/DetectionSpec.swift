import Foundation

/// Describes how to detect whether a provider's tool is installed locally.
struct DetectionSpec {
    /// Filesystem paths to check for existence (supports ~ expansion).
    let paths: [String]

    /// CLI command names to look for via `which`.
    let commands: [String]

    /// VS Code/Cursor/Windsurf extension ID prefixes to scan for.
    let extensionPatterns: [String]

    init(
        paths: [String] = [],
        commands: [String] = [],
        extensionPatterns: [String] = []
    ) {
        self.paths = paths
        self.commands = commands
        self.extensionPatterns = extensionPatterns
    }
}

/// Describes how to resolve an icon for a provider, checked in priority order:
/// 1. App bundle icon from `appBundlePaths`
/// 2. VS Code extension icon (uses `DetectionSpec.extensionPatterns`)
/// 3. Cached web icon from `faviconDomain` or `iconURLOverrides`
struct IconSpec {
    /// macOS .app bundle paths to extract icons from.
    let appBundlePaths: [String]

    /// Domain used for favicon fetching (e.g. "cursor.com").
    let faviconDomain: String?

    /// Explicit icon URLs to try before generic favicon (e.g. GitHub org avatars).
    let iconURLOverrides: [URL]

    init(
        appBundlePaths: [String] = [],
        faviconDomain: String? = nil,
        iconURLOverrides: [URL] = []
    ) {
        self.appBundlePaths = appBundlePaths
        self.faviconDomain = faviconDomain
        self.iconURLOverrides = iconURLOverrides
    }
}
