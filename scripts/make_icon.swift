#!/usr/bin/env swift
// 生成 AppIcon：纯文字 wordmark，不绘制图形
//
// 用法：swift scripts/make_icon.swift [输出目录]
// 输出目录默认 Assets.xcassets/AppIcon.appiconset
//
// 设计：深色渐变底 + 白色粗体「Niu / Pod」两行。
// 两行断在驼峰处，字号可以放到很大，40pt 的小图标上依然清晰可辨。

import CoreGraphics
import CoreText
import Foundation
import ImageIO

let outputDir: String = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Assets.xcassets/AppIcon.appiconset"

// MARK: - 配色

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}

let backdropTop = rgb(0x4A, 0x4A, 0x4E)
let backdropBottom = rgb(0x16, 0x16, 0x18)
let wordColor = rgb(0xFF, 0xFF, 0xFF)

// MARK: - 绘制

func drawBackdrop(_ ctx: CGContext, _ s: CGFloat) {
    let colors = [backdropTop, backdropBottom] as CFArray
    guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: colors, locations: [0, 1]) else { return }
    // 注意：CGContext 的 y 轴与视觉方向相反（y=0 在视觉下方），
    // 所以这里从 y=s 画到 y=0，才能让 backdropTop 落在视觉顶部
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: s * 0.5, y: s),
                           end: CGPoint(x: s * 0.5, y: 0),
                           options: [])
}

/// 在「左上原点」坐标系里居中绘制一行文字
///
/// CoreText 用 CG 坐标（原点左下），这里统一在视觉坐标（原点左上）里算好位置
/// 再换算成 CG 的基线坐标，避免调用方关心翻转。
func drawCenteredLine(_ ctx: CGContext,
                      _ text: String,
                      _ s: CGFloat,
                      fontSize: CGFloat,
                      visualCenterY: CGFloat) {
    let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)

    // 直接用 CoreText 的可变属性串：纯 Foundation 环境下 NSAttributedString.Key
    // 的部分常量不可见，绕开它更稳
    guard let attr = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0) else { return }
    CFAttributedStringReplaceString(attr, CFRangeMake(0, 0), text as CFString)
    let full = CFRangeMake(0, CFAttributedStringGetLength(attr))
    CFAttributedStringSetAttribute(attr, full, kCTFontAttributeName, font)
    CFAttributedStringSetAttribute(attr, full, kCTForegroundColorAttributeName, CGColor.white)
    CFAttributedStringSetAttribute(attr, full, kCTKernAttributeName,
                                   NSNumber(value: -fontSize * 0.03))

    let line = CTLineCreateWithAttributedString(attr)
    let bounds = CTLineGetBoundsWithOptions(line, [])

    // 视觉坐标：文字块顶部 = 中心 - 高度/2
    let visualTop = visualCenterY - bounds.height / 2
    // 基线距文字块顶部 = bounds.maxY（相对基线的 ascent）
    let baselineVisualY = visualTop + bounds.maxY

    ctx.textPosition = CGPoint(
        x: (s - bounds.width) / 2 - bounds.origin.x,
        y: s - baselineVisualY                      // 视觉 y → CG y
    )
    CTLineDraw(line, ctx)
}

func drawWordmark(_ ctx: CGContext, _ s: CGFloat) {
    let fontSize = s * 0.315
    let lineGap = s * 0.036

    // 先量一次行高，用于整体垂直居中
    let probe = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
    let ascent = CTFontGetAscent(probe)
    let descent = CTFontGetDescent(probe)
    let lineHeight = ascent + descent

    // 两行按大写字母高度排布，视觉中心按「两行 + 行距」的整体高度居中
    let total = (ascent + descent) * 2 + lineGap
    let top = (s - total) / 2
    let firstCenter = top + lineHeight / 2
    let secondCenter = top + lineHeight + lineGap + lineHeight / 2

    drawCenteredLine(ctx, "Niu", s, fontSize: fontSize, visualCenterY: firstCenter)
    drawCenteredLine(ctx, "Pod", s, fontSize: fontSize, visualCenterY: secondCenter)
}

func renderIcon(pixels: Int) -> CGImage? {
    let s = CGFloat(pixels)
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels,
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        return nil
    }
    // 先铺底色，避免任何透明像素（App Store 要求图标无 alpha 通道）
    ctx.setFillColor(backdropBottom)
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    drawBackdrop(ctx, s)
    drawWordmark(ctx, s)

    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        return false
    }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

// MARK: - 尺寸清单

/// (像素边长, 倍数, 文件名)
let specs: [(Int, Int, String)] = [
    (20, 2, "icon-40.png"),
    (20, 3, "icon-60.png"),
    (29, 2, "icon-58.png"),
    (29, 3, "icon-87.png"),
    (40, 2, "icon-80.png"),
    (40, 3, "icon-120.png"),
    (60, 2, "icon-120-alt.png"),
    (60, 3, "icon-180.png"),
    // iPad：不打包 iPad 版，但补上可以消掉 actool 的警告
    (76, 2, "icon-152.png"),
    (167, 1, "icon-167.png"),
    (1024, 1, "icon-1024.png"),
]

let fm = FileManager.default
try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

var failures: [String] = []
for (point, scale, name) in specs {
    let pixels = point * scale
    guard let image = renderIcon(pixels: pixels) else {
        failures.append("\(name) 渲染失败"); continue
    }
    let path = (outputDir as NSString).appendingPathComponent(name)
    if !writePNG(image, to: path) {
        failures.append("\(name) 写盘失败")
    } else {
        print("  ✓ \(name) (\(pixels)×\(pixels))")
    }
}

if failures.isEmpty {
    print("AppIcon 已生成 → \(outputDir)")
} else {
    print("以下文件失败：\(failures.joined(separator: ", "))")
    exit(1)
}
