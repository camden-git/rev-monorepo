// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RevKit",
    // macOS is only supported so the pure game-math functions can be unit-tested on the host
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RevKit", targets: ["RevKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pawelmajcher/SwiftyH3.git", exact: "0.4.1"),
    ],
    targets: [
        .target(
            name: "RevKit",
            dependencies: ["SwiftyH3"]
        ),
        .testTarget(
            name: "RevKitTests",
            dependencies: ["RevKit", "SwiftyH3"]
        ),
    ]
)
