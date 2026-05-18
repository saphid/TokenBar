import Foundation

enum CodyProviderDef: DetectionOnlyProvider {
    static let typeId = "cody"
    static let defaultName = "Cody"
    static let iconSymbol = "doc.text.magnifyingglass"
    static let dashboardURL: URL? = URL(string: "https://sourcegraph.com/cody/manage")

    static let detection = DetectionSpec(
        extensionPatterns: ["sourcegraph.cody-ai-"]
    )
    static let iconSpec = IconSpec(faviconDomain: "sourcegraph.com")
}
