// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DockNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DockNotch",
            path: "Sources/DockNotch"
        )
    ]
)
