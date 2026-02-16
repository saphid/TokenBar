// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TokenBar",
            path: "Sources/TokenBar"
        )
    ]
)
