import CoreGraphics
import Foundation

/// 转盘手势判定：区分「点按」与「旋转」。
///
/// 三个判据各有各的漏洞，必须一起用：
/// - **瞬时值**（起点 → 当前点的距离 / 净转角）：沿环转一整圈回到出发点时两者都归零，
///   会被判成点按 —— 手一松就误触 MENU（转动中突然返回上一级）。
/// - **峰值**（位移峰值 / 净转角峰值）：挡得住转圈，但挡不住「小幅来回搓」——
///   真人搓转盘常是 ±5°、每次几 pt 的动作，峰值始终在阈值内，照样误触。
/// - **纯累计路程**：搓动能识别了，可原地抖动的位移会被一路累加、永不抵消，
///   长按中心键时手一抖就被判成旋转、把长按取消掉。
///
/// 所以最终取：峰值（转圈）+ **带死区的累计路程**（搓动）。
/// 死区把静止时的手抖过滤掉，长按就不再被误伤。
struct WheelDragTracker {
    /// 判定为「点按」的最大位移（峰值）
    static let tapSlop: CGFloat = 10
    /// 判定为「点按」的最大净转角（度，峰值）。
    ///
    /// 取旋转步进（22°）的一半：太大吃掉正常点按，太小挡不住慢速转圈。
    static let tapRotationTolerance: Double = 11
    /// 单次位移小于此值视为「静止抖动」，不计入路程。
    ///
    /// 手指按在屏上不动时，触摸坐标每帧仍有 1~2pt 的漂移；超过这个量级的
    /// 来回移动就已经是「搓」而不是「抖」了。
    static let jitterDeadzone: CGFloat = 2
    /// 判定为「点按」的最大有效路程（已过滤抖动）。
    ///
    /// 24pt ≈ 在环上来回搓两三下的量：比这动得多就是在转，不是点。
    static let tapPathTolerance: CGFloat = 24

    /// 转盘中心（视图坐标）
    let center: CGPoint

    /// 出现过的最大位移（起点 → 当前点）
    private(set) var peakDisplacement: CGFloat = 0
    /// 出现过的最大净转角（相对按下时角度，绝对值）
    private(set) var peakRotation: Double = 0
    /// 有效路程（单次位移超过 `jitterDeadzone` 才累加）
    private(set) var pathLength: CGFloat = 0

    private var startLocation: CGPoint?
    private var startAngle: Double?
    private var lastLocation: CGPoint?
    private var lastAngle: Double?

    init(center: CGPoint) {
        self.center = center
    }

    /// 本次手势是否应判为点按：三个条件都在阈值内才算
    var isTap: Bool {
        peakDisplacement <= Self.tapSlop
            && peakRotation <= Self.tapRotationTolerance
            && pathLength <= Self.tapPathTolerance
    }

    /// 记录一次移动，返回本段的角度增量（第一个采样点返回 nil，仅建立基准）
    mutating func move(to location: CGPoint) -> Double? {
        defer { lastLocation = location }
        guard let start = startLocation else {
            startLocation = location
            startAngle = angle(of: location)
            lastAngle = startAngle
            return nil
        }

        peakDisplacement = max(peakDisplacement, hypot(location.x - start.x, location.y - start.y))
        if let last = lastLocation {
            let step = hypot(location.x - last.x, location.y - last.y)
            if step > Self.jitterDeadzone { pathLength += step }
        }

        let current = angle(of: location)
        defer { lastAngle = current }
        if let startAngle {
            peakRotation = max(peakRotation, abs(Self.shortestDelta(from: startAngle, to: current)))
        }
        guard let previous = lastAngle else { return nil }
        return Self.shortestDelta(from: previous, to: current)
    }

    private func angle(of point: CGPoint) -> Double {
        atan2(point.y - center.y, point.x - center.x) * 180 / .pi
    }

    /// 归一化角度差到 [-180, 180]，避免跨越 ±180 时方向反转
    static func shortestDelta(from a: Double, to b: Double) -> Double {
        var d = b - a
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }
}
