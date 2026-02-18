import Foundation

enum ChatGPTProviderDef: DetectionOnlyProvider {
    static let typeId = "chatgpt"
    static let defaultName = "ChatGPT"
    static let iconSymbol = "bubble.left.and.text.bubble.right"
    static let dashboardURL: URL? = URL(string: "https://chatgpt.com/#settings")

    static let detection = DetectionSpec(paths: ["/Applications/ChatGPT.app"])
    static let iconSpec = IconSpec(
        appBundlePaths: ["/Applications/ChatGPT.app"],
        faviconDomain: "chatgpt.com"
    )
}
