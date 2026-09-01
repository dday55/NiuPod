#!/usr/bin/env swift
// 校验界面质感：读取模拟器截图，采样转盘区像素
//
// 用法：swift scripts/verify_chrome.swift <screenshot.png>
//
// 无法肉眼看图时，用这个确认「金属质感」确实渲染出来了，而不是一块平涂灰色：
//   1. 转盘区纵向应有明显明暗变化（线性渐变）
//   2. 转盘金属环绕一圈应有明暗变化（锥形渐变 / 拉丝反光）
// 位置比例来自 UI 测试实测值（window 402×874，wheel frame 52.15,533.32,297.7²）。

import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count > 1 else {
    print("用法：swift scripts/verify_chrome.swift <screenshot.png>")
    exit(2)
}
let path = args[1]

guard let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL),
      let image = CGImage(pngDataProviderSource: provider, decode: nil,
                          shouldInterpolate: false, intent: .defaultIntent) else {
    print("!! 读不到 \(path)")
    exit(1)
}

let W = image.width
let H = image.height
let ctx = CGContext(data: nil, width: W, height: H,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
let raw = ctx.data!.bindMemory(to: UInt8.self, capacity: W * H * 4)

func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let cx = min(max(x, 0), W - 1)
    let cy = min(max(y, 0), H - 1)
    let o = (W * cy + cx) * 4
    return (Int(raw[o]), Int(raw[o + 1]), Int(raw[o + 2]))
}

var failures: [String] = []
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "✓" : "✗") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    if !ok { failures.append(label) }
}

print("截图 \(W)×\(H)")
print("参考点：左上 \(pixel(5, 5))  中上 \(pixel(W / 2, 40))  中下 \(pixel(W / 2, H - 40))")

// MARK: - 0. 自动定位分区

/// 屏幕区几乎全是白的（菜单行只占少量像素），转盘区是银灰机身。
/// 按「每行高亮像素占比」找它们的分界，避免硬编码比例——布局一改坐标就失效。
func brightRatio(atY y: Int) -> Double {
    var hit = 0, total = 0
    for x in stride(from: Int(Double(W) * 0.30), to: Int(Double(W) * 0.70), by: 3) {
        total += 1
        if pixel(x, y).0 >= 250 { hit += 1 }
    }
    return total > 0 ? Double(hit) / Double(total) : 0
}

var zoneTop = Int(Double(H) * 0.5)
for y in stride(from: Int(Double(H) * 0.40), to: H - 2, by: 2) {
    if brightRatio(atY: y) < 0.5 { zoneTop = y; break }
}
print(String(format: "转盘区起点 y=%.3f (屏幕区到此结束)", Double(zoneTop) / Double(H)))

// MARK: - 1. 转盘区纵向渐变

// 取左侧空白竖条（转盘是居中的，左边界约在 19%，5% 处确定是机身）
let stripX = Int(Double(W) * 0.05)
var vertical: [Int] = []
let step = max(2, (H - zoneTop) / 14)
for y in stride(from: zoneTop + 4, to: H - 4, by: step) {
    let p = pixel(stripX, y)
    vertical.append(p.0)
    print(String(format: "  纵向 y=%.3f  RGB=(%d,%d,%d)", Double(y) / Double(H), p.0, p.1, p.2))
}
let vMin = vertical.min() ?? 0
let vMax = vertical.max() ?? 0
check("转盘区纵向有明暗变化（非平涂）", vMax - vMin >= 12,
      "红通道 \(vMin)...\(vMax)，跨度 \(vMax - vMin)")
check("转盘区整体是银灰色调", vMin >= 140 && vMax <= 255,
      "区间 \(vMin)...\(vMax)")

// MARK: - 2. 转盘与机身的关系

// 真机结构：白色转盘直接嵌在银色拉丝机身上，转盘明显比机身亮。
// （之前这里验的是转盘外圈的金属环，那圈与真机不符，已去掉。）
// 转盘直径取 62.4% 屏宽（UI 测试实测值，真机为 61.5%）
let wheelD = Double(W) * 0.6235
let cx = Double(W) * 0.5
let cy = Double(zoneTop) + 12 * 3 + wheelD / 2      // 上边距 12pt × 3x

// 盘面：中心上方，避开刻字与中心键
let faceY = Int(cy - wheelD * 0.20)
let face = pixel(Int(cx), faceY)
print("  盘面 (\(Int(cx)),\(faceY)) RGB=\(face)")

// 机身：转盘区左边缘多处取平均，单点容易被渐变亮处带偏
var bodySum = 0
var bodyCount = 0
for y in stride(from: zoneTop + 10, to: H - 10, by: max(2, (H - zoneTop) / 12)) {
    bodySum += pixel(stripX, y).0
    bodyCount += 1
}
let bodyAvg = bodyCount > 0 ? bodySum / bodyCount : 0
print("  机身均值（左边缘 \(bodyCount) 点）红通道 = \(bodyAvg)")

check("转盘盘面是浅灰白", face.0 >= 238 && face.0 <= 255, "红通道 \(face.0)")
check("转盘明显亮于机身（白色转盘嵌银色机身）", face.0 - bodyAvg >= 18,
      "盘面 \(face.0) vs 机身均值 \(bodyAvg)，差 \(face.0 - bodyAvg)")
check("机身是银灰而非纯白", bodyAvg <= 235, "均值 \(bodyAvg)")

if failures.isEmpty {
    print("\n质感校验通过")
} else {
    print("\n!! 校验失败：\(failures.joined(separator: ", "))")
    exit(1)
}
