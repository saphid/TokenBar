import Foundation

enum AmazonQProviderDef: DetectionOnlyProvider {
    static let typeId = "amazon-q"
    static let defaultName = "Amazon Q"
    static let iconSymbol = "a.circle"
    static let dashboardURL: URL? = URL(string: "https://aws.amazon.com/q/developer/")

    static let detection = DetectionSpec(
        paths: ["/Applications/Amazon Q.app", "~/.aws/amazonq"],
        commands: ["q"],
        extensionPatterns: ["amazonwebservices.amazon-q-vscode-"]
    )
    static let iconSpec = IconSpec(
        appBundlePaths: ["/Applications/Amazon Q.app"],
        faviconDomain: "aws.amazon.com"
    )
}
