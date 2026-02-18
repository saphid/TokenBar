import Foundation

enum ContinueProviderDef: DetectionOnlyProvider {
    static let typeId = "continue"
    static let defaultName = "Continue"
    static let iconSymbol = "arrow.right.circle"
    static let dashboardURL: URL? = URL(string: "https://continue.dev")

    static let detection = DetectionSpec(
        paths: ["~/.continue"],
        extensionPatterns: ["continue.continue-"]
    )
    static let iconSpec = IconSpec(faviconDomain: "continue.dev")
}
