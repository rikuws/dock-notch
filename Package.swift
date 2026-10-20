// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DockNotch",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "DockNotch",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/DockNotch",
            linkerSettings: [
                // The app bundle carries Sparkle.framework in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
