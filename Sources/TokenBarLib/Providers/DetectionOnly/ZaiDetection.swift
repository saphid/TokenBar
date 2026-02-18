import Foundation

enum ZaiProviderDef: DetectionOnlyProvider {
    static let typeId = "zai"
    static let defaultName = "Z.AI"
    static let iconSymbol = "bolt.fill"
    static let dashboardURL: URL? = URL(string: "https://z.ai/manage-apikey/rate-limits")

    static let detection = DetectionSpec(commands: ["crush", "zai"])
    static let iconSpec = IconSpec(faviconDomain: "z.ai")
}
