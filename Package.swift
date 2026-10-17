// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Point",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Point",
            path: "Sources/Point",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
