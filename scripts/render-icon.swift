// 渲染 Portside 应用图标(工单 12):SF Symbol「sailboat」白色帆船 + 深海蓝圆角底,
// 输出 1024px PNG;后续由 package-app.sh 经 iconset → iconutil 生成 icns。
// (工单原文写锚形 anchor,实机运行时该符号不可用,改 sailboat——码头停船,语义不变。
// 用法:swift scripts/render-icon.swift <输出.png>
// 只在需要重生成 Packaging/AppIcon.icns 时跑一次;icns 入库,打包不依赖本脚本。
import AppKit

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("用法:swift scripts/render-icon.swift <输出.png>\n".data(using: .utf8)!)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let size: CGFloat = 1024
// 底衬四周留 ~10% 透明边(macOS 图标惯例:系统不替你裁,自带边距才有呼吸感)
let margin: CGFloat = 102
let tileSize = size - margin * 2

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let tile = NSBezierPath(
    roundedRect: NSRect(x: margin, y: margin, width: tileSize, height: tileSize),
    xRadius: tileSize * 0.225, yRadius: tileSize * 0.225
)
NSColor(calibratedRed: 0.10, green: 0.29, blue: 0.38, alpha: 1).setFill() // 深海蓝
tile.fill()

// 白色锚形:模板符号先画黑,再 sourceAtop 整体染白
guard let symbol = NSImage(systemSymbolName: "sailboat", accessibilityDescription: nil) else {
    FileHandle.standardError.write("SF Symbol sailboat 不可用\n".data(using: .utf8)!)
    exit(1)
}
let configured = symbol.withSymbolConfiguration(
    NSImage.SymbolConfiguration(pointSize: tileSize * 0.52, weight: .medium)
)!
let symbolSize = configured.size
let symbolRect = NSRect(
    x: (size - symbolSize.width) / 2, y: (size - symbolSize.height) / 2,
    width: symbolSize.width, height: symbolSize.height
)
let tinted = NSImage(size: symbolSize)
tinted.lockFocus()
configured.draw(in: NSRect(origin: .zero, size: symbolSize))
NSColor.white.setFill()
NSRect(origin: .zero, size: symbolSize).fill(using: .sourceAtop)
tinted.unlockFocus()
tinted.draw(in: symbolRect)
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG 编码失败\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: output)
print("已渲染 \(output.path)")
