// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Horizon",
    platforms: [.macOS("26.0")],
    targets: [
        // 纯逻辑，不碰系统接口，可以单元测试
        .target(name: "HorizonCore", path: "Sources/HorizonCore"),
        .executableTarget(name: "Horizon", dependencies: ["HorizonCore"], path: "Sources/Horizon"),
        .testTarget(name: "HorizonCoreTests", dependencies: ["HorizonCore"], path: "Tests/HorizonCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
