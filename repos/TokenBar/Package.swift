// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "TokenBarLib",
            path: "Sources/TokenBarLib"
        ),
        .executableTarget(
            name: "TokenBar",
            dependencies: ["TokenBarLib"],
            path: "Sources/TokenBar"
        ),
        .testTarget(
            name: "TokenBarTests",
            dependencies: ["TokenBarLib"],
            path: "Tests/TokenBarTests"
        )
    ]
)
