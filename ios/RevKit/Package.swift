// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RevKit",
    platforms: [.iOS(.v17)],
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
    ]
)
