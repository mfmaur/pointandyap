// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PointAndYap",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Updates: checks pointandyap.com/appcast.xml, downloads in the background, verifies the EdDSA signature.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .executableTarget(
            name: "PointAndYap",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/PointAndYap",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle.framework is embedded in Contents/Frameworks by scripts/build.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
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
