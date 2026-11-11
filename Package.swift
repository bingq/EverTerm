// swift-tools-version:5.9
// Needs Xcode 26 / Swift 6.2+ toolchain (SwiftTerm requires it).
import PackageDescription

let package = Package(
    name: "KeepTerm",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.3"),
    ],
    targets: [
        .executableTarget(
            name: "KeepTerm",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
    ]
)
