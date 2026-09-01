import CoreGraphics
import XCTest
@testable import NiuPod

/// 转盘手势状态机单测：新手势识别
///
/// 回归重点：转一圈是长时间连续手势，SwiftUI 中途重建识别器时会换一个
/// startLocation。以前靠 `dragStart == nil`（只在 onEnded 里清空）判断新手势，
/// 这种重建会被当成同一次手势继续用旧基准 → 增量算错（转着转着没反应），
/// 峰值也不再增长 → 抬手被判成点按、误触 MENU 返回上一级（看着像被「重置」）。
final class WheelGestureStateTests: XCTestCase {

    func testTracksGestureWithSameStartLocation() {
        let state = WheelGestureState()
        state.begin(at: CGPoint(x: 10, y: 10), center: .zero)
        XCTAssertTrue(state.isTracking(startLocation: CGPoint(x: 10, y: 10)),
                      "同一次手势的按下位置不变，应继续跟踪")
    }

    func testNewStartLocationRestartsTracking() {
        let state = WheelGestureState()
        state.begin(at: CGPoint(x: 10, y: 10), center: .zero)
        state.didRotate = true
        state.accumulated = 30

        XCTAssertFalse(state.isTracking(startLocation: CGPoint(x: 12, y: 10)),
                       "按下位置变了就是新的一次手势，必须重新初始化")

        // 重新初始化后，上一次手势的旋转痕迹不能带过来
        state.begin(at: CGPoint(x: 12, y: 10), center: .zero)
        XCTAssertEqual(state.accumulated, 0)
        XCTAssertFalse(state.didRotate)
        XCTAssertTrue(state.isTracking(startLocation: CGPoint(x: 12, y: 10)))
    }

    func testResetClearsTracking() {
        let state = WheelGestureState()
        state.begin(at: .zero, center: .zero)
        state.startButton = .menu
        state.didRotate = true

        state.reset()

        XCTAssertFalse(state.isTracking(startLocation: .zero))
        XCTAssertNil(state.startButton)
        XCTAssertFalse(state.didRotate)
        XCTAssertEqual(state.accumulated, 0)
    }

    /// 抬手补发点击的条件是「没长按 && 没转过 && 判据为点按」。
    /// 判据可能因手势中途重建而重置成「点按」，didRotate 是最后一道保险。
    func testDidRotateSurvivesTrackerReplacement() {
        let state = WheelGestureState()
        state.begin(at: CGPoint(x: 100, y: 0), center: .zero)
        state.didRotate = true

        // 手势被系统重建：新的 tracker 自身会判为「点按」
        state.tracker = WheelDragTracker(center: .zero)
        XCTAssertTrue(state.isTap, "新 tracker 本身会判为点按")

        XCTAssertTrue(state.didRotate,
                      "本次手势已经转过，不能因为判据被重置就补发一次点击")
    }
}
