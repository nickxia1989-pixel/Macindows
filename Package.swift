// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Macindows",
    platforms: [.macOS("26.0")],
    targets: [
        // 纯逻辑，不碰系统接口，可以单元测试
        .target(name: "MacindowsCore", path: "Sources/MacindowsCore"),
        .executableTarget(name: "Macindows", dependencies: ["MacindowsCore"], path: "Sources/Macindows"),
        .testTarget(name: "MacindowsCoreTests", dependencies: ["MacindowsCore"], path: "Tests/MacindowsCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
