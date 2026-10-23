// swift-tools-version:6.0
// Portside · 服务码头 —— SwiftPM 包：PortsideKit 库（业务逻辑）+ portside 可执行（UI 装配）。
// 零第三方依赖、零网络、零遥测。语言模式 Swift 5，规避严格并发检查。

import PackageDescription

let package = Package(
    name: "portside",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PortsideKit", targets: ["PortsideKit"]),
        .executable(name: "portside", targets: ["portside"]),
    ],
    targets: [
        .target(name: "PortsideKit"),
        .executableTarget(
            name: "portside",
            dependencies: ["PortsideKit"]
        ),
        .testTarget(
            name: "PortsideKitTests",
            dependencies: ["PortsideKit"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
