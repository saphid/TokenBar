import Foundation

enum TabnineProviderDef: DetectionOnlyProvider {
    static let typeId = "tabnine"
    static let defaultName = "Tabnine"
    static let iconSymbol = "text.word.spacing"
    static let dashboardURL: URL? = URL(string: "https://app.tabnine.com")

    static let detection = DetectionSpec(
        paths: ["~/.tabnine"],
        extensionPatterns: ["tabnine.tabnine-vscode-"]
    )
    static let iconSpec = IconSpec(faviconDomain: "tabnine.com")
}
