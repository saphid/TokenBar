import Foundation

enum AiderProviderDef: DetectionOnlyProvider {
    static let typeId = "aider"
    static let defaultName = "Aider"
    static let iconSymbol = "wrench.and.screwdriver"
    static let dashboardURL: URL? = URL(string: "https://aider.chat")

    static let detection = DetectionSpec(commands: ["aider"])
    static let iconSpec = IconSpec(
        faviconDomain: "aider.chat",
        iconURLOverrides: [URL(string: "https://avatars.githubusercontent.com/u/150185854?s=128")!]
    )
}
