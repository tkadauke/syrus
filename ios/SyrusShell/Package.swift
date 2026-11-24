// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SyrusShell",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "SyrusHaptics", targets: ["SyrusHaptics"])],
    targets: [
        .target(name: "SyrusHaptics"),
        .testTarget(name: "SyrusHapticsTests", dependencies: ["SyrusHaptics"]),
    ]
)
