import Foundation

enum MinimaxProviderDef: DetectionOnlyProvider {
    static let typeId = "minimax"
    static let defaultName = "Minimax"
    static let iconSymbol = "brain"
    static let dashboardURL: URL? = URL(string: "https://platform.minimax.io")

    static let detection = DetectionSpec(
        paths: ["/Applications/MiniMax.app", "~/.mini-agent"],
        commands: ["mini-agent"]
    )
    static let iconSpec = IconSpec(
        appBundlePaths: ["/Applications/MiniMax.app"],
        faviconDomain: "minimaxi.com"
    )
}
