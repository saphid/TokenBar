import Foundation

enum GeminiProviderDef: DetectionOnlyProvider {
    static let typeId = "gemini"
    static let defaultName = "Gemini"
    static let iconSymbol = "diamond"
    static let dashboardURL: URL? = URL(string: "https://aistudio.google.com")

    static let detection = DetectionSpec(
        paths: ["/Applications/Gemini.app", "/Applications/Antigravity.app"],
        commands: ["gemini"]
    )
    static let iconSpec = IconSpec(
        appBundlePaths: ["/Applications/Gemini.app", "/Applications/Antigravity.app"],
        faviconDomain: "gemini.google.com"
    )
}
