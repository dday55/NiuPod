import CoreGraphics
import XCTest
@testable import NiuPod

/// 转盘解释器单测：覆盖「不抬手连续转一圈」。
///
/// XCUITest 做不了这个动作——`press(forDuration:thenDragTo:)` 只能给一个终点、
/// 中间按直线插值，而转一圈正是误触 MENU 与中途断触的发生场景。
///
/// 核心回归：连续转动时 SwiftUI 可能重建手势识别器并换一个 `startLocation`
/// （有时每一帧都换）。旧实现在这种情况下整段重来（重新 begin），
/// 峰值 / 累计角 / didRotate 全部清零 → 转盘不响应（断触），
/// 抬手又被判成点按、误触 MENU 返回上一级（看着像「重置」）。
final class WheelGestureInterpreterTests: XCTestCase {

    private let center = CGPoint(x: 150, y: 150)
    private let radius: CGFloat = 125
    private let centerRadius: CGFloat = 45
    /// 采样半径：环上刻字附近，手指实际落点
    private var ring: CGFloat { radius * 0.75 }

    /// 一整圈（120 帧 × 3°）转下来的预期值。
    ///
    /// 比 360° 少 9°，来自开头三帧：
    ///   1. 第 1 帧 `begin` 只建角度基准，`move` 返回 nil，不产生增量；
    ///   2. 第 2、3 帧还在点按死区里 —— `isTap` 要求峰值位移 ≤ `tapSlop`(10pt)，
    ///      在 93.75pt 的采样半径上要转过约 9° 才超过它。
    /// 这段空行程是故意的：一次点按不能顺带把列表滚一格。
    /// 它只在手势开头出现一次，之后转多久都不再掉步。
    private let fullCircleAngle = 351.0
    /// 351° / 22° ≈ 15 步（余 21° 留在累加器里，下一次转动接着走）
    private let fullCircleSteps = 15

    private func makeInterpreter() -> WheelGestureInterpreter {
        WheelGestureInterpreter(center: center, radius: radius, centerRadius: centerRadius,
                                stepDegrees: 22, highlightSlop: 3)
    }

    private func point(at degrees: Double, radius: CGFloat? = nil) -> CGPoint {
        let r = radius ?? ring
        return CGPoint(x: center.x + r * cos(degrees * .pi / 180),
                       y: center.y + r * sin(degrees * .pi / 180))
    }

    /// 沿环转动，可选地每 n 帧换一次按下点（模拟识别器重建）
    ///
    /// - Parameters:
    ///   - from: 起始角度（手指当前所在的角度，用来衔接上一段转动）
    ///   - degrees: 转过的总角度（带符号）
    ///   - perFrame: 每帧转过多少度
    ///   - rebuildEvery: 每多少帧换一次按下点；0 表示不换（正常情况）
    /// - Returns: (累计步数, 累计角度增量, 最后的手指位置)
    @discardableResult
    private func spin(_ interpreter: WheelGestureInterpreter,
                      from: Double = 0,
                      degrees: Double,
                      perFrame: Double = 3,
                      rebuildEvery: Int = 0) -> (steps: Int, angle: Double, last: CGPoint) {
        var start = point(at: from)
        var current = from
        var steps = 0
        var angle = 0.0
        var frame = 0
        let direction: Double = degrees >= 0 ? 1 : -1

        while abs(current - from) < abs(degrees) - 0.0001 {
            if frame > 0, rebuildEvery > 0, frame % rebuildEvery == 0 {
                // 识别器在手指**当前所在的位置**重启
                start = point(at: current)
            }
            current += perFrame * direction
            let update = interpreter.update(startLocation: start, location: point(at: current))
            steps += update.steps
            angle += update.angleDelta ?? 0
            frame += 1
        }
        return (steps, angle, point(at: current))
    }

    // MARK: - 转一圈：步数与角度

    func testFullCircleEmitsSteps() {
        let wheel = makeInterpreter()

        let result = spin(wheel, degrees: 360)

        XCTAssertEqual(result.angle, fullCircleAngle, accuracy: 0.5)
        XCTAssertEqual(result.steps, fullCircleSteps)
    }

    /// 识别器每隔几帧重启一次：判定状态必须原样续上
    func testFullCircleWithRecognizerRebuildKeepsRotating() {
        let wheel = makeInterpreter()

        let result = spin(wheel, degrees: 360, rebuildEvery: 5)

        // 与不重建时完全一样：换 startLocation 不能吃掉任何增量
        XCTAssertEqual(result.angle, fullCircleAngle, accuracy: 0.5)
        XCTAssertEqual(result.steps, fullCircleSteps)
    }

    /// 极端情况：识别器**每一帧**都重启。
    /// 旧实现每帧都重新 begin，等于每帧都在建基准 → 一次增量都发不出去（转盘完全不动）。
    func testPerFrameRecognizerRebuildStillRotates() {
        let wheel = makeInterpreter()

        let result = spin(wheel, degrees: 360, rebuildEvery: 1)

        XCTAssertEqual(result.angle, fullCircleAngle, accuracy: 0.5)
        XCTAssertEqual(result.steps, fullCircleSteps, "每帧重建也必须一步不丢")
    }

    func testReverseCircleEmitsNegativeSteps() {
        let wheel = makeInterpreter()

        let result = spin(wheel, degrees: -360, rebuildEvery: 1)

        XCTAssertEqual(result.angle, -fullCircleAngle, accuracy: 0.5)
        XCTAssertEqual(result.steps, -fullCircleSteps)
    }

    // MARK: - 转一圈：不许补发点击

    func testFullCircleDoesNotFireTapOnRelease() {
        let wheel = makeInterpreter()

        let result = spin(wheel, degrees: 360)
        let button = wheel.finish(location: result.last)

        XCTAssertNil(button, "转过一圈的手势不能补发点击")
    }

    /// 转一整圈回到原点：位移与净转角都归零，靠 didRotate 挡住
    func testFullCircleBackToStartDoesNotFireTap() {
        let wheel = makeInterpreter()

        _ = spin(wheel, degrees: 360)
        let button = wheel.finish(location: point(at: 0))

        XCTAssertNil(button, "首尾重合时峰值判据会失效，必须靠 didRotate 兜住")
    }

    func testSpuriousEndMidRotationDoesNotFireTapLater() {
        let wheel = makeInterpreter()

        // 转半圈时系统插进来一次假的结束事件
        let halfway = spin(wheel, degrees: 180)
        XCTAssertNil(wheel.finish(location: halfway.last),
                     "已经转过的手势，假的结束也不能补发点击")

        // 手指其实没抬，接着刚才的位置转完剩下半圈
        let done = spin(wheel, from: 180, degrees: 180)
        XCTAssertEqual(done.steps, 8, "后半圈照样要一步一步走完")

        XCTAssertNil(wheel.finish(location: done.last),
                     "中途断过一次也不能在真正抬手时补发点击")
    }

    // MARK: - 点按仍然要灵

    func testTapOnMenuStillFires() {
        let wheel = makeInterpreter()

        let press = point(at: -90)
        let first = wheel.update(startLocation: press, location: press)
        XCTAssertTrue(first.isFirstFrame)
        XCTAssertEqual(first.highlighted, .menu)

        // 手指轻微抖动（每帧 1pt 左右）
        for offset in [0.6, -0.4, 0.5, -0.3] {
            let moved = CGPoint(x: press.x + offset, y: press.y + offset)
            let update = wheel.update(startLocation: press, location: moved)
            XCTAssertFalse(update.isRotating, "点按不能被判成旋转")
            XCTAssertEqual(update.highlighted, .menu)
        }

        XCTAssertEqual(wheel.finish(location: press), .menu)
    }

    func testTapOnCenterStillFires() {
        let wheel = makeInterpreter()

        let press = center
        _ = wheel.update(startLocation: press, location: press)
        XCTAssertEqual(wheel.finish(location: press), .center)
    }

    /// 一次触摸收尾后，下一次触摸必须是干净的
    func testFreshTapAfterRotationWorks() {
        let wheel = makeInterpreter()

        let done = spin(wheel, degrees: 360)
        XCTAssertNil(wheel.finish(location: done.last))
        wheel.cancel()

        let press = point(at: -90)
        _ = wheel.update(startLocation: press, location: press)
        XCTAssertEqual(wheel.finish(location: press), .menu)
    }

    /// 按下点离手指当前位置很远 → 确实是一次新的触摸（结束事件丢失的兜底）
    func testDistantRestartStartsNewGesture() {
        let wheel = makeInterpreter()

        // 手指停在 90°（下 = 播放暂停）
        _ = spin(wheel, degrees: 90)
        // 模拟结束事件丢失：手指直接跳到 180°（左 = 上一首）重新按下
        let press = point(at: 180)
        let update = wheel.update(startLocation: press, location: press)

        XCTAssertTrue(update.isFirstFrame, "按下点离得远，应当按新的一次触摸处理")
        XCTAssertEqual(update.highlighted, .previous)
        XCTAssertEqual(wheel.finish(location: press), .previous)
    }

    // MARK: - 按键分区

    func testButtonSectors() {
        let wheel = makeInterpreter()

        XCTAssertEqual(wheel.button(at: point(at: -90)), .menu)
        XCTAssertEqual(wheel.button(at: point(at: 90)), .playPause)
        XCTAssertEqual(wheel.button(at: point(at: 0)), .next)
        XCTAssertEqual(wheel.button(at: point(at: 180)), .previous)
        XCTAssertEqual(wheel.button(at: center), .center)
        // 环外（点到盘外）归到中心键，避免误触
        XCTAssertEqual(wheel.button(at: point(at: 0, radius: radius + 20)), .center)
    }
}
