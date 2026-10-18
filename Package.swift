// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PointAndYap",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "PointAndYap",
            path: "Sources/PointAndYap",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PointAndYapTests",
            dependencies: ["PointAndYap"],
            path: "Tests/PointAndYapTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
