import Foundation

enum OpenRouterProviderDef: DetectionOnlyProvider {
    static let typeId = "openrouter"
    static let defaultName = "OpenRouter"
    static let iconSymbol = "network"
    static let dashboardURL: URL? = URL(string: "https://openrouter.ai")

    static let detection = DetectionSpec(
        extensionPatterns: ["khaled.vscode-openrouter-"]
    )
    static let iconSpec = IconSpec(faviconDomain: "openrouter.ai")
}
