#!/usr/bin/env swift
// 校验生成的 AppIcon：读取 PNG，采样/扫描像素确认构图
//
// 用法：swift scripts/verify_icon.swift [png路径] [边长]
// 默认校验源图 1024；传产物里的 AppIcon60x60@2x.png 120 可验证编译后的图标
//
// 无法肉眼看图时的客观验证手段：
//   - 背景是深色渐变（顶部比底部亮）
//   - 白色文字确实画上去了（扫描出足量近白像素）
//   - 文字居中、纵向落在两行的预期区间
//   - 无 alpha 通道（App Store 要求）

import CoreGraphics
import Foundation
import ImageIO

let path = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Assets.xcassets/AppIcon.appiconset/icon-1024.png"
let S: Int = CommandLine.arguments.count > 2
    ? (Int(CommandLine.arguments[2]) ?? 1024)
    : 1024

guard let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL),
      let image = CGImage(pngDataProviderSource: provider, decode: nil,
                          shouldInterpolate: false, intent: .defaultIntent) else {
    print("!! 读不到 \(path)")
    exit(1)
}

guard let ctx = CGContext(data: nil, width: S, height: S,
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    print("!! 无法创建上下文"); exit(1)
}
ctx.draw(image, in: CGRect(x: 0, y: 0, width: S, height: S))
// 绑定成 UInt8 缓冲区，方便按字节取像素
let raw = ctx.data!.bindMemory(to: UInt8.self, capacity: S * S * 4)

// MARK: - 背景渐变

/// 读取「左上原点」坐标的像素
func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let offset = (S * y + x) * 4
    return (Int(raw[offset]), Int(raw[offset + 1]), Int(raw[offset + 2]))
}

var failures: [String] = []
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "✓" : "✗") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    if !ok { failures.append(label) }
}

// MARK: - 背景渐变

let topBg = pixel(S / 2, 6)
let bottomBg = pixel(S / 2, S - 7)
check("背景顶部是深色", topBg.0 < 110, "RGB=\(topBg)")
check("背景底部是深色", bottomBg.0 < 90, "RGB=\(bottomBg)")
check("背景自上而下变暗（渐变而非纯色）", topBg.0 > bottomBg.0 + 8,
      "顶部 \(topBg.0) vs 底部 \(bottomBg.0)")

// 四角也应是背景色，说明文字没有溢出到边缘
let cornerTol = 40
let corners = [pixel(8, 8), pixel(S - 9, 8), pixel(8, S - 9), pixel(S - 9, S - 9)]
check("四角均为背景色", corners.allSatisfy { abs($0.0 - topBg.0) < cornerTol || abs($0.0 - bottomBg.0) < cornerTol },
      "\(corners)")

// MARK: - 扫描白色文字

var minX = S, maxX = 0, minY = S, maxY = -1, whiteCount = 0, sumX = 0
let whiteThreshold = 200
for y in stride(from: 0, to: S, by: 2) {
    for x in stride(from: 0, to: S, by: 2) {
        let p = pixel(x, y)
        guard p.0 >= whiteThreshold, p.1 >= whiteThreshold, p.2 >= whiteThreshold else { continue }
        whiteCount += 1
        sumX += x
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
    }
}

let sampled = (S / 2) * (S / 2)
let whiteRatio = Double(whiteCount) / Double(sampled)
check("存在足量白色文字像素", whiteRatio > 0.04,
      "占比 \(String(format: "%.1f%%", whiteRatio * 100))")

let textWidth = maxX - minX
let textHeight = maxY - minY
check("文字宽度合理（约占 45%~85%）",
      Double(textWidth) / Double(S) > 0.45 && Double(textWidth) / Double(S) < 0.85,
      "宽 \(textWidth)/\(S)")
check("文字高度合理（约占 45%~80%）",
      Double(textHeight) / Double(S) > 0.45 && Double(textHeight) / Double(S) < 0.80,
      "高 \(textHeight)/\(S)")

// 水平居中
let centerX = sumX / max(whiteCount, 1)
check("文字水平居中", abs(centerX - S / 2) < S / 20,
      "白像素重心 x=\(centerX)，画布中心 \(S / 2)")

// 垂直居中
let centerY = (minY + maxY) / 2
check("文字垂直居中", abs(centerY - S / 2) < S / 12,
      "纵向范围 \(minY)...\(maxY)，中点 \(centerY)")

// MARK: - 尺寸与通道

let alpha = image.alphaInfo
let hasAlpha = alpha != .none && alpha != .noneSkipFirst && alpha != .noneSkipLast
check("无 alpha 通道", !hasAlpha, "alphaInfo=\(alpha.rawValue)")
check("尺寸 \(S)×\(S)", image.width == S && image.height == S, "\(image.width)×\(image.height)")

if failures.isEmpty {
    print("\nAppIcon 校验通过")
} else {
    print("\n!! 校验失败：\(failures.joined(separator: ", "))")
    exit(1)
}
