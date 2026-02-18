import Foundation

enum ClineProviderDef: DetectionOnlyProvider {
    static let typeId = "cline"
    static let defaultName = "Cline"
    static let iconSymbol = "text.line.first.and.arrowtriangle.forward"
    static let dashboardURL: URL? = nil

    static let detection = DetectionSpec(
        extensionPatterns: ["saoudrizwan.claude-dev-", "cline.cline-"]
    )
    static let iconSpec = IconSpec(
        faviconDomain: "cline.bot",
        iconURLOverrides: [URL(string: "https://avatars.githubusercontent.com/u/173998279?s=128")!]
    )
}
