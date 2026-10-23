// swift-tools-version:6.0
// Portside · 服务码头 —— SwiftPM 包：PortsideKit 库（业务逻辑）+ portside 可执行（UI 装配）
// + portside-host-sim（工单 08 测试替身：模拟 Portside 宿主进程，验证生命周期解耦）。
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
        // 工单 08 集成测试替身（adr/0001 解耦验证）：自成进程组的"宿主"进程，
        // 真跑 ShellProcessController 起服务后原地挂起、无任何退出清理路径——
        // 测试对它整组 kill -9 即等价「杀掉 Portside」，不必让测试进程自杀。
        .executableTarget(
            name: "portside-host-sim",
            dependencies: ["PortsideKit"]
        ),
        .testTarget(
            name: "PortsideKitTests",
            dependencies: ["PortsideKit", "portside-host-sim"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
