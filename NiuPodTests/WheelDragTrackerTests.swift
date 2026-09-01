import CoreGraphics
import XCTest
@testable import NiuPod

/// 转盘手势判定单测：点按 vs 旋转
///
/// 回归重点：
/// 1. **转一圈回到出发点不能判成点按**——只看首尾直线距离的话，一整圈下来首尾
///    距离几乎为 0，手一松就误触 MENU（转动中突然返回上一级）。
/// 2. **原地抖动必须仍然算点按**——否则长按中心键时手一抖就被判成旋转，
///    长按被取消（真机上手指不可能绝对静止）。
final class WheelDragTrackerTests: XCTestCase {

    private let center = CGPoint(x: 120, y: 120)
    private let radius: CGFloat = 100

    /// 环上某个角度对应的点（0° 在 3 点方向，正角顺时针，与 App 内一致）
    private func point(at degree: Double, radius: CGFloat? = nil) -> CGPoint {
        let r = radius ?? self.radius
        let rad = degree * .pi / 180
        return CGPoint(x: center.x + r * cos(rad), y: center.y + r * sin(rad))
    }

    /// 沿环走一段：从 from 度按 step 度走到 to 度，返回 tracker
    private func rotate(from: Double, to: Double, step: Double = 5) -> WheelDragTracker {
        var tracker = WheelDragTracker(center: center)
        var angle = from
        _ = tracker.move(to: point(at: angle))
        while abs(to - angle) > 0.01 {
            angle += to > from ? step : -step
            if (to > from && angle > to) || (to < from && angle < to) { angle = to }
            _ = tracker.move(to: point(at: angle))
        }
        return tracker
    }

    // MARK: - 点按

    func testTapWithoutMovementIsTap() {
        var tracker = WheelDragTracker(center: center)
        _ = tracker.move(to: point(at: -90))          // MENU 位置按下
        XCTAssertTrue(tracker.isTap)
    }

    func testTinyJitterStillCountsAsTap() {
        // 手指按下时的轻微抖动：位移 1pt、转角 ~0.6°，不能被判成旋转
        var tracker = WheelDragTracker(center: center)
        _ = tracker.move(to: point(at: -90))
        _ = tracker.move(to: point(at: -90.6, radius: radius - 1))
        XCTAssertLessThan(tracker.peakDisplacement, WheelDragTracker.tapSlop)
        XCTAssertLessThan(tracker.peakRotation, WheelDragTracker.tapRotationTolerance)
        XCTAssertTrue(tracker.isTap)
    }

    /// 长按的关键：**静止手抖**不能被累计成路程。
    /// 手指按在屏上不动时每帧仍有 1~2pt 漂移，若按「路程累计」判定，
    /// 长按中心键时手一抖就被判成旋转、把长按取消（真机手指不可能绝对静止）。
    func testLongPressJitterStillCountsAsTap() {
        var tracker = WheelDragTracker(center: center)
        _ = tracker.move(to: point(at: -90))
        // 每帧：径向漂 1pt、偶尔切向漂 ~1.4pt，合成约 1.7pt，低于 2pt 死区
        for i in 0..<36 {
            let r = radius - (i % 2 == 0 ? 1 : 0)
            let degree = -90 + (i % 3 == 0 ? 0.8 : 0)
            _ = tracker.move(to: point(at: degree, radius: r))
        }
        XCTAssertLessThan(tracker.peakDisplacement, WheelDragTracker.tapSlop,
                          "抖动位移峰值 \(tracker.peakDisplacement) 应仍在点按范围内")
        XCTAssertLessThan(tracker.peakRotation, WheelDragTracker.tapRotationTolerance,
                          "抖动转角峰值 \(tracker.peakRotation) 应仍在点按范围内")
        XCTAssertEqual(tracker.pathLength, 0, "静止抖动应被死区全部过滤")
        XCTAssertTrue(tracker.isTap, "原地抖动必须仍判为点按，否则长按会被取消")
    }

    // MARK: - 旋转（回归：转一圈回到原点）

    func testFullCircleBackToStartIsNotATap() {
        // 从 MENU 出发顺时针转一整圈回到原点：
        // 首尾直线距离 ≈ 0、净转角也归零，但峰值留住中途的大角度 → 判为旋转
        let tracker = rotate(from: -90, to: 270)
        XCTAssertGreaterThan(tracker.peakRotation, 90, "应留住中途经过的大角度")
        XCTAssertGreaterThan(tracker.peakDisplacement, 100, "位移峰值应接近直径")
        XCTAssertFalse(tracker.isTap, "转了一整圈不能判成点按，否则松手误触 MENU")
    }

    func testArcNearCenterIsNotATapEvenWhenShort() {
        // 在中心键附近小幅画弧：位移只有几 pt，但转过 90° —— 应判为旋转，
        // 否则手指在中心键边缘一划就触发「确认」
        var tracker = WheelDragTracker(center: center)
        for degree in stride(from: 0.0, through: 90.0, by: 15.0) {
            _ = tracker.move(to: point(at: degree, radius: 4))
        }
        XCTAssertLessThan(tracker.peakDisplacement, WheelDragTracker.tapSlop)
        XCTAssertGreaterThan(tracker.peakRotation, 45, "应识别出明显的角度变化")
        XCTAssertFalse(tracker.isTap)
    }

    /// 小幅来回搓：每次位移 4pt、角度 ±2.3°，位移峰值与转角峰值都在点按阈值内，
    /// 只有「有效路程」能识别出来。真人搓转盘就是这个动作，漏了就会持续误触。
    func testSmallBackAndForthScrubIsRotation() {
        var tracker = WheelDragTracker(center: center)
        _ = tracker.move(to: point(at: -90))
        for i in 0..<20 {
            let offset = i % 2 == 0 ? 4.0 : -4.0
            _ = tracker.move(to: point(at: -90 + offset / radius * 60))
        }
        XCTAssertGreaterThan(tracker.pathLength, WheelDragTracker.tapPathTolerance,
                             "来回搓的有效路程 \(tracker.pathLength) 应超过阈值")
        XCTAssertFalse(tracker.isTap, "来回搓是旋转，不能判成点按")
    }

    func testDeadzoneFiltersSubPixelJitter() {
        // 每次只动 1pt（低于死区 1.5pt）：20 次也不该被累计成路程
        var tracker = WheelDragTracker(center: center)
        _ = tracker.move(to: point(at: -90))
        for i in 0..<20 {
            _ = tracker.move(to: point(at: -90, radius: radius - (i % 2 == 0 ? 1 : 0)))
        }
        XCTAssertEqual(tracker.pathLength, 0, "低于死区的抖动不应计入路程")
        XCTAssertTrue(tracker.isTap)
    }

    func testQuarterTurnIsRotation() {
        let tracker = rotate(from: -90, to: 0)
        XCTAssertFalse(tracker.isTap)
        XCTAssertGreaterThan(tracker.peakRotation, 80)
    }

    // MARK: - 角度增量

    func testDeltaSignFollowsClockwiseSweep() {
        var tracker = WheelDragTracker(center: center)
        _ = tracker.move(to: point(at: -90))
        let delta = tracker.move(to: point(at: -80))
        XCTAssertNotNil(delta)
        XCTAssertGreaterThan(delta ?? 0, 0, "顺时针（角度增大）应为正增量")
    }

    func testDeltaWrapsAcrossPlusMinus180() {
        // 跨过 ±180 不能反向：170° → -170° 是 +20°，不是 -340°
        var tracker = WheelDragTracker(center: center)
        _ = tracker.move(to: point(at: 170))
        let delta = tracker.move(to: point(at: -170))
        XCTAssertEqual(delta ?? 0, 20, accuracy: 0.001)
    }
}
