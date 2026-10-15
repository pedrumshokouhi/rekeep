// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RekeepKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "RekeepKit", targets: ["RekeepKit"]),
    ],
    targets: [
        .target(
            name: "RekeepKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "RekeepKitTests", dependencies: ["RekeepKit"]),
    ]
)
