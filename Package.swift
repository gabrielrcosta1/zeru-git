// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GitAgent",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "GitAgent",
            path: "Sources/GitAgent"
        )
    ]
)
