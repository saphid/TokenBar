import Foundation

enum OllamaProviderDef: DetectionOnlyProvider {
    static let typeId = "ollama"
    static let defaultName = "Ollama"
    static let iconSymbol = "server.rack"
    static let dashboardURL: URL? = nil

    static let detection = DetectionSpec(
        paths: ["/Applications/Ollama.app", "~/.ollama"],
        commands: ["ollama"]
    )
    static let iconSpec = IconSpec(
        appBundlePaths: ["/Applications/Ollama.app"],
        faviconDomain: "ollama.com"
    )
}
