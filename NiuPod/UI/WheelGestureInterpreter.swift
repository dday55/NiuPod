import CoreGraphics
import Foundation

/// 转盘触摸序列的解释器：把一联串事件翻译成「旋转步进 / 点按」。
///
/// 从 `ClickWheel` 里抽出来是为了能单测**完整事件序列**。XCUITest 做不了
/// 「不抬手连续转一圈」——`press(forDuration:thenDragTo:)` 只能给一个终点、
/// 中间按直线插值，而转一圈正是误触 MENU 与中途断触的发生场景，光靠 UI 测试验证不到。
///
/// 这里只做判定与状态推进，触感、拖尾、业务回调等副作用留在 View 里。
final class WheelGestureInterpreter {
    /// 一次手势更新的结果
    struct Update {
        /// 本次的角度增量（度），仅在旋转模式下有值
        var angleDelta: Double?
        /// 本次跨过的整步数（带符号）
        var steps = 0
        /// 当前应高亮的按键；旋转中为 nil
        var highlighted: WheelButton?
        /// 本次事件是否是新手势的第一帧（View 据此决定是否启动长按计时）
        var isFirstFrame = false
        /// 本次是否已进入旋转模式（View 据此取消长按）
        var isRotating = false
    }

    /// 触摸没断、识别器却换了 `startLocation` 时，新按下点与手指当前位置的最大距离。
    ///
    /// 识别器重启时新按下点就在手指处，距离接近 0；只有「真的换了一次触摸
    /// （且结束事件丢了）」才可能差很远。留这道保险是为了不至于把两次
    /// 触摸并成一次。
    static let resumeTolerance: CGFloat = 80

    private let state = WheelGestureState()
    private let stepDegrees: Double
    /// 高亮的保持范围：位移超过这么多就先熄灭，避免转动时按键闪一下像误触
    private let highlightSlop: CGFloat

    private var center: CGPoint
    private var radius: CGFloat
    private var centerRadius: CGFloat

    init(center: CGPoint, radius: CGFloat, centerRadius: CGFloat,
         stepDegrees: Double = 22, highlightSlop: CGFloat = 3) {
        self.center = center
        self.radius = radius
        self.centerRadius = centerRadius
        self.stepDegrees = stepDegrees
        self.highlightSlop = highlightSlop
    }

    /// 布局变化时同步几何（手势进行中转盘的 center / 半径不会变，安全）
    func configure(center: CGPoint, radius: CGFloat, centerRadius: CGFloat) {
        self.center = center
        self.radius = radius
        self.centerRadius = centerRadius
    }

    /// 处理一次手势更新
    func update(startLocation: CGPoint, location: CGPoint) -> Update {
        var update = Update()

        guard state.isActive else {
            // 全新的一次触摸：整段重来
            begin(startLocation: startLocation, location: location, into: &update)
            return update
        }

        if state.ended {
            // 已经结束过却又来了事件 → 那只是一次「假的结束」（识别器被系统
            // 中断过），原样续上。这里不能重新 begin：峰值、didRotate、累计角
            // 一旦清零，转着转着就会丢步（断触），抬手还可能被判成点按。
            state.ended = false
        } else if !state.isTracking(startLocation: startLocation) {
            // 连续转动时 SwiftUI 可能中途重建手势识别器：同一个触摸会换一个
            // startLocation（有时每一帧都换）。这里必须**原样续上**——
            // 不清峰值、不清累计角、不清 didRotate。
            //
            // 早先在这里整段重来（begin），等于把一次连续触摸切成前后两段：
            // 后一段峰值从零长起、didRotate 被清掉 → 抬手又被判成点按、
            // 误触 MENU 返回上一级（看着像「重置」）；累计角清零则表现为
            // 转着转着丢半步。重建每帧都发生时更糟——每帧都在建基准，
            // 一次增量都发不出去，转盘彻底不动。
            guard distance(startLocation, state.lastLocation ?? location) <= Self.resumeTolerance else {
                // 按下点离手指当前位置很远：确实是一次新的触摸（结束事件丢了）
                begin(startLocation: startLocation, location: location, into: &update)
                return update
            }
            state.startLocation = startLocation
        }

        state.lastLocation = location
        guard let delta = state.tracker?.move(to: location) else { return update }
        guard !state.isTap else {
            // 尚未越过点按阈值：只更新高亮，不做旋转。
            // 手指已经明显移动但还没到旋转阈值时先熄灭高亮——
            // 转动途中按键闪一下，看着就像误触。
            update.highlighted = (state.peakDisplacement ?? 0) <= highlightSlop
                ? state.startButton : nil
            return update
        }

        // 旋转模式：didRotate 是峰值判据之外的第二道保险——
        // 沿环转一整圈回到原点时位移与净转角都归零，判据会重新变成「点按」。
        update.isRotating = true
        update.angleDelta = delta
        state.didRotate = true
        state.accumulated += delta
        while abs(state.accumulated) >= stepDegrees {
            let step = state.accumulated > 0 ? 1 : -1
            state.accumulated -= Double(step) * stepDegrees
            update.steps += step
        }
        return update
    }

    /// 手势结束：返回应补发的按键，nil 表示不补发
    ///
    /// 长按的判断不在这里——那是 View 的状态（计时器是否已触发过）。
    ///
    /// 注意这里**不**清状态：结束事件可能是假的（见 `update`）。真正的收尾
    /// 由 View 在无后续事件时调用 `cancel()` 完成。
    func finish(location: CGPoint) -> WheelButton? {
        state.lastLocation = location
        _ = state.tracker?.move(to: location)
        state.ended = true
        return (!state.didRotate && state.isTap) ? state.startButton : nil
    }

    /// 放弃当前手势（View 在确认抬手后调用），不产生点按
    func cancel() {
        state.reset()
    }

    /// 某个位置落在哪个键上
    func button(at point: CGPoint) -> WheelButton {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let dist = hypot(dx, dy)
        if dist <= centerRadius { return .center }
        guard dist <= radius else { return .center }   // 环外归到中心键，避免误触
        let angle = atan2(dy, dx) * 180 / .pi
        switch angle {
        case -45...45: return .next
        case 45...135: return .playPause
        case -135..<(-45): return .menu
        default: return .previous
        }
    }

    // MARK: - 私有

    private func begin(startLocation: CGPoint, location: CGPoint, into update: inout Update) {
        state.begin(at: startLocation, center: center)
        // 按下瞬间就锁定按键：后续手指怎么漂移都不改判
        state.startButton = button(at: startLocation)
        state.lastLocation = location
        update.isFirstFrame = true
        update.highlighted = state.startButton
        // 第一个点只建立角度基准，不产生增量
        _ = state.tracker?.move(to: location)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
