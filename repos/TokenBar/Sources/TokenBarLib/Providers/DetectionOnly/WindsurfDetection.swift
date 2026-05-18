import Foundation

enum WindsurfProviderDef: DetectionOnlyProvider {
    static let typeId = "windsurf"
    static let defaultName = "Windsurf"
    static let iconSymbol = "wind"
    static let dashboardURL: URL? = URL(string: "https://codeium.com/account")

    static let detection = DetectionSpec(
        paths: ["/Applications/Windsurf.app", "~/Library/Application Support/Windsurf"],
        commands: ["windsurf"]
    )
    static let iconSpec = IconSpec(
        appBundlePaths: ["/Applications/Windsurf.app"],
        faviconDomain: "codeium.com"
    )
}
