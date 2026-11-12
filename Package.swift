// swift-tools-version:5.9
// Needs a Swift 6.4+ toolchain (SwiftTerm 1.99.3 does not compile with 6.2.3).
import PackageDescription

let package = Package(
    name: "EverTerm",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.3"),
    ],
    targets: [
        // Logic with no AppKit or SwiftTerm, so it can be unit-tested anywhere (`swift test`).
        .target(name: "EverTermCore"),
        .executableTarget(
            name: "EverTerm",
            dependencies: ["EverTermCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
            // Dock icon while running with `swift run` (no .app bundle yet); see Icon/README.md.
            resources: [.copy("Resources/AppIcon.png")]
        ),
        .testTarget(name: "EverTermCoreTests", dependencies: ["EverTermCore"]),
    ]
)
