// swift-tools-version:5.9
// Needs Xcode 26 / Swift 6.2+ toolchain (SwiftTerm requires it).
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
            dependencies: ["EverTermCore", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .testTarget(name: "EverTermCoreTests", dependencies: ["EverTermCore"]),
    ]
)
