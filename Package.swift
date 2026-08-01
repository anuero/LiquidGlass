// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LiquidGlass",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "LiquidGlass", targets: ["LiquidGlass"]),
    ],
    targets: [
        .target(name: "LiquidGlass"),
        .testTarget(name: "LiquidGlassTests", dependencies: ["LiquidGlass"]),
    ]
)
