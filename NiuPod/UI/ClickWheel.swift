import SwiftUI
import UIKit

/// 转盘上的按键分区
/// 非 private：`WheelGestureState` 要跨文件被单测覆盖
enum WheelButton {
    case menu, previous, next, playPause, center

    /// 扇区角度（SwiftUI 坐标系：0° 向右、正角顺时针），与 `button(at:)` 划分一致。
    /// 环上四键各占 90°；中心键没有扇区。
    var sectorAngles: (start: Angle, end: Angle)? {
        switch self {
        case .menu:      return (.degrees(-135), .degrees(-45))   // 上
        case .playPause: return (.degrees(45), .degrees(135))     // 下
        case .next:      return (.degrees(-45), .degrees(45))     // 右
        case .previous:  return (.degrees(135), .degrees(225))    // 左
        case .center:    return nil
        }
    }
}

/// iPod 转盘（Click Wheel）
///
/// 交互还原要点：
/// - **环形滑动**：手指沿环转动，累计角度每达到 `stepDegrees`（22°，接近实机
///   的「咔哒」手感）触发一步，顺时针为下、逆时针为上，每步带轻微触感反馈。
/// - **四区点击**：上 MENU / 左 上一首 / 右 下一首 / 下 播放暂停。
/// - **中心键**：确认进入；**长按**则交给 `onLongCenter`，用于弹出曲目操作菜单
///   （真 iPod 上长按中心键也是呼出「评级 / 加入歌单」这类菜单）。
///
/// 旋转与点击用同一个手势识别（移动距离小于阈值判为点击），避免手势冲突。
/// 长按需要独立的定时器：手指静止时 DragGesture 不会再发 onChanged 事件。
struct ClickWheel: View {
    var onRotate: (Int) -> Void = { _ in }
    /// 连续角度增量（度），供列表做像素级跟手滚动；与 onRotate 的 22° 步进互补
    var onAngle: (Double) -> Void = { _ in }
    var onMenu: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onNext: () -> Void = {}
    var onPlayPause: () -> Void = {}
    var onCenter: () -> Void = {}
    var onLongCenter: () -> Void = {}

    /// 每步的角度阈值
    private static let stepDegrees: Double = 22
    /// 按键高亮的保持范围：移动超过这么多就先熄灭，避免转动时按键闪一下像误触
    private static let tapHighlightSlop: CGFloat = 3
    /// 长按中心键的触发时长
    private static let longPressDuration: TimeInterval = 0.45
    /// 拖尾最多保留的轨迹点数（插值后需要更多点；太多会糊成一片、也拖慢绘制，
    /// 太少会断断续续）
    private static let maxTrailPoints = 32
    /// 相邻采样点之间的插值步长（度）：步长越小越连续，快速转动也不会断点
    private static let trailInterpolationStep: Double = 6
    /// 抬手补发点击的延后时长。
    ///
    /// 识别器被系统中断时会先来一次「假的」onEnded，紧接着又是同一个触摸的
    /// onChanged。留出这一小段窗口让假结束能被撤销，否则手没松却被当成一次
    /// 点按（转动中突然返回上一级）。50ms ≈ 三帧，人手抬起重按远慢于此。
    private static let tapFireDelay: TimeInterval = 0.05

    @State private var pressed: WheelButton?
    /// 转盘手势的解释器：把事件序列翻译成「旋转 / 点按」。
    /// 用**引用类型**持有：手势回调里每帧都在改，引用语义不依赖 View 重建时的
    /// 值拷贝，比 @State 存 struct 稳。
    @State private var interpreter = WheelGestureInterpreter(center: .zero,
                                                             radius: 1,
                                                             centerRadius: 0,
                                                             stepDegrees: Self.stepDegrees,
                                                             highlightSlop: Self.tapHighlightSlop)
    @State private var haptic = UIImpactFeedbackGenerator(style: .light)
    @State private var longPressTimer: Timer?
    @State private var didLongPress = false
    /// 待落地的抬手收尾（可能带一次补发的点击）
    @State private var pendingTap: DispatchWorkItem?

    // 旋转拖尾：一串沿手指轨迹渐隐的光点，只在旋转时出现，松手即消失
    @State private var trailPoints: [TrailPoint] = []
    /// 当前旋转强度（0~1，越快越亮、彗尾越长）
    @State private var trailIntensity: Double = 0

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            // 中心键：真机约为转盘直径的 29%（11mm / 38mm），为触控与观感放大到 36%
            // （下面用的是半径，所以是 side * 0.18）
            let centerRadius = side * 0.18

            ZStack {
                // 1. 转盘盘面：真机是**白色盘面直接嵌在机身里**，外圈并没有金属环。
                //    金属感属于机身区域（见 PodDevice 的 wheelZoneGradient）。
                //    盘面用径向渐变做出「中间亮、边缘微收」的平面感，非常克制。
                Circle()
                    .fill(PodTheme.wheelFaceGradient(radius: side / 2))

                // 2. 凹槽圈：盘面与机身之间那道细缝。上缘压暗、下缘提亮，
                //    表现「盘面略低于机身平面」的沉台结构。
                Circle()
                    .strokeBorder(PodTheme.wheelGrooveGradient, lineWidth: max(1.5, side * 0.012))
                    .allowsHitTesting(false)

                // 3. 外圈极细的缝：让盘面与机身的边界更清晰
                Circle()
                    .stroke(PodTheme.wheelGap, lineWidth: 0.75)
                    .padding(-max(0.75, side * 0.002))
                    .allowsHitTesting(false)

                // 4. 玻璃高光：盘面是亮面塑料/玻璃，顶部有一道很淡的弧形反光，
                //    这是「塑料质感」而不是「金属质感」的关键。
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.50),
                                Color.white.opacity(0.10),
                                Color.white.opacity(0),
                            ],
                            center: UnitPoint(x: 0.5, y: 0.20),
                            startRadius: 0,
                            endRadius: side * 0.60
                        )
                    )
                    .allowsHitTesting(false)

                // 5. 按压分区：按下的那一块环形扇区微微压暗，做出「键帽下沉」效果。
                //    平时完全不可见，保持真机转盘的干净盘面。
                pressedSectorLayer(side: side, centerRadius: centerRadius)

                // 6. 旋转拖尾：一串光点沿手指真实轨迹排布，头亮尾淡、灵动跟手；
                //    只在旋转过程中出现，松手立即消失。
                rotationTrailLayer(side: side, center: center)

                // 6. 环上刻字
                glyphLayer(side: side)

                // 7. 中心确认键：与盘面同色，靠一圈凹槽线区分；按下时整颗键帽下沉。
                Circle()
                    .fill(PodTheme.centerGradient(radius: centerRadius))
                    .overlay(
                        Circle().strokeBorder(PodTheme.centerRingGradient, lineWidth: max(1, side * 0.005))
                    )
                    .overlay(
                        // 键帽内侧再压一圈极淡的阴影，让凹槽有深度
                        Circle().stroke(Color.black.opacity(0.10), lineWidth: 0.5)
                            .padding(1.5)
                    )
                    .overlay {
                        // 按下：键帽整体压暗 + 顶部阴影，模拟物理下沉
                        if pressed == .center {
                            Circle().fill(Color.black.opacity(0.14))
                        }
                    }
                    .frame(width: centerRadius * 2, height: centerRadius * 2)
                    .scaleEffect(pressed == .center ? 0.955 : 1)
                    .shadow(color: pressed == .center ? Color.black.opacity(0.25) : .clear, radius: 2, y: 1)
                    .accessibilityIdentifier("centerButton")
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Circle().inset(by: -4))
            .gesture(wheelGesture(center: center, radius: side / 2, centerRadius: centerRadius))
            .animation(.easeOut(duration: 0.08), value: pressed)
            .accessibilityElement()
            .accessibilityLabel("转盘")
            .accessibilityIdentifier("clickWheel")
            .onAppear { haptic.prepare() }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: - 按压分区

    /// 按下的四键分区：一个环形扇区，只压在盘面外圈（中心键之外），
    /// 用淡淡的压暗 + 内圈阴影模拟「按键下沉」。
    @ViewBuilder
    private func pressedSectorLayer(side: CGFloat, centerRadius: CGFloat) -> some View {
        if let button = pressed, let angles = button.sectorAngles {
            WheelSector(startAngle: angles.start, endAngle: angles.end,
                        innerRadius: centerRadius + max(1, side * 0.008))
                .fill(
                    RadialGradient(
                        colors: [
                            Color.black.opacity(0.18),
                            Color.black.opacity(0.10),
                            Color.black.opacity(0.03),
                        ],
                        center: .center,
                        startRadius: centerRadius,
                        endRadius: side / 2
                    )
                )
                .overlay(
                    // 内圈阴影：靠近中心键的一侧更暗，显得被按进去
                    WheelSector(startAngle: angles.start, endAngle: angles.end,
                                innerRadius: centerRadius + max(1, side * 0.008))
                        .stroke(
                            LinearGradient(
                                colors: [Color.black.opacity(0.18), Color.black.opacity(0.04)],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: max(0.8, side * 0.004)
                        )
                )
                .allowsHitTesting(false)
        }
    }

    // MARK: - 旋转拖尾

    /// 旋转拖尾：按手指最近一段轨迹采样一串光点，头亮尾淡、大小渐收，
    /// 半径与角度都跟手（不固定在某一圈/某一条线上），看起来更灵动。
    /// 平时完全不可见，保持真机盘面的干净。
    ///
    /// 整条拖尾画在**一个 Canvas** 里（见 `TrailCanvas`）：早先是 ForEach 叠 48 个
    /// 带 RadialGradient 的 Circle，转一圈要连续拖好几秒，每帧重建几十个渐变视图
    /// 会把帧率直接打下去，手感就变成「转着转着断了」。
    @ViewBuilder
    private func rotationTrailLayer(side: CGFloat, center: CGPoint) -> some View {
        if trailPoints.count > 1 {
            TrailCanvas(points: trailPoints.map { pointPosition($0, center: center) },
                        side: side,
                        intensity: trailIntensity)
                .allowsHitTesting(false)
        }
    }

    /// 轨迹点（角度/半径）转成盘面坐标
    private func pointPosition(_ point: TrailPoint, center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + point.radius * cos(point.angle * .pi / 180),
                y: center.y + point.radius * sin(point.angle * .pi / 180))
    }

    // MARK: - 刻字

    @ViewBuilder
    private func glyphLayer(side: CGFloat) -> some View {
        let glyphSize = side * 0.115
        // 真机刻字靠近盘缘：中心约在 0.40 × 直径处（即半径的 0.80），
        // 避免贴向中心圆、按压区更符合直觉
        let radius = side * 0.40

        Group {
            // 真机刻字是细体小字，不是粗体；颜色与其余符号一致
            glyphView(side: side, size: glyphSize) {
                Text("MENU")
                    .font(.system(size: side * 0.056, weight: .medium))
                    .tracking(side * 0.005)
                    .foregroundStyle(PodTheme.wheelGlyph)
            }
            .offset(y: -radius)
            .scaleEffect(pressed == .menu ? 0.9 : 1)
            .opacity(pressed == .menu ? 0.45 : 1)

            glyphView(side: side, size: glyphSize) {
                // 真机是实心刻字：❙◀◀（外侧竖线 + 两个紧贴的左向三角）
                SeekGlyph(direction: .backward)
                    .fill(PodTheme.wheelGlyph)
                    .frame(width: side * 0.075, height: side * 0.055)
            }
            .offset(x: -radius)
            .scaleEffect(pressed == .previous ? 0.9 : 1)
            .opacity(pressed == .previous ? 0.45 : 1)

            glyphView(side: side, size: glyphSize) {
                SeekGlyph(direction: .forward)
                    .fill(PodTheme.wheelGlyph)
                    .frame(width: side * 0.075, height: side * 0.055)
            }
            .offset(x: radius)
            .scaleEffect(pressed == .next ? 0.9 : 1)
            .opacity(pressed == .next ? 0.45 : 1)

            glyphView(side: side, size: glyphSize) {
                // ▶❙❙ —— 一个三角加两条竖线，与真机一致
                PlayPauseGlyph()
                    .fill(PodTheme.wheelGlyph)
                    .frame(width: side * 0.075, height: side * 0.055)
            }
            .offset(y: radius)
            .scaleEffect(pressed == .playPause ? 0.9 : 1)
            .opacity(pressed == .playPause ? 0.45 : 1)
        }
        .allowsHitTesting(false)
    }

    private func glyphView<Content: View>(
        side: CGFloat,
        size: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(width: size * 1.6, height: size)
    }

    // MARK: - 手势

    private func wheelGesture(center: CGPoint, radius: CGFloat, centerRadius: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // 还有事件进来 → 上一次 onEnded 是假的（识别器被系统中断过），
                // 撤掉那次待落的收尾，让解释器把这次触摸原样续下去。
                cancelPendingTap()
                interpreter.configure(center: center, radius: radius, centerRadius: centerRadius)
                let update = interpreter.update(startLocation: value.startLocation,
                                                location: value.location)

                if update.isFirstFrame {
                    cancelLongPress()
                    pressed = update.highlighted
                    // 按下瞬间若为「中心键」，启动长按计时。
                    // 手指静止不动时 DragGesture 不会再发 onChanged，
                    // 所以必须用定时器而不是靠后续事件判断。
                    if update.highlighted == .center { scheduleLongPress() }
                    return
                }

                guard update.isRotating else {
                    // 尚未越过点按阈值：保持按下时锁定的分区，不做旋转。
                    // 手指已经明显移动但还没到旋转阈值时先熄灭高亮——
                    // 转动途中按键闪一下，看着就像误触。
                    pressed = update.highlighted
                    return
                }

                // 进入旋转模式 → 长按作废
                cancelLongPress()
                pressed = nil
                let delta = update.angleDelta ?? 0
                let location = value.location
                let angle = Self.angle(of: location, from: center)
                // 记录轨迹点：沿手指真实路径排布（含半径变化），
                // 两点之间按角度插值，快速转动也不会断成一串小点
                appendTrailPoint(TrailPoint(angle: angle,
                                            radius: distance(location, center)))
                // 速度越快强度越高 → 彗尾更长更亮
                let speed = min(1, abs(delta) / 8)
                trailIntensity = min(1, trailIntensity * 0.72 + speed * 0.28)
                // 每次手势更新都输出连续角度，滚动不再“按行跳”，而是像素级跟手
                onAngle(delta)
                for _ in 0..<abs(update.steps) {
                    let step = update.steps > 0 ? 1 : -1
                    onRotate(step)
                    haptic.impactOccurred(intensity: 0.7)
                }
            }
            .onEnded { value in
                cancelLongPress()
                // 长按已经消费掉这次手势，不再补发普通点击
                let button = didLongPress ? nil : interpreter.finish(location: value.location)
                pressed = nil
                trailPoints = []
                trailIntensity = 0
                didLongPress = false
                scheduleTap(button)
            }
    }

    // MARK: - 抬手收尾

    /// 安排一次抬手收尾：`button` 非空则补发点击。
    ///
    /// 延后 `tapFireDelay` 再落地：期间只要还有事件进来（手没真抬起，
    /// 只是识别器被系统中断了一下），`cancelPendingTap()` 就会把它撤销，
    /// 手势继续，不会被误判成一次点按。
    private func scheduleTap(_ button: WheelButton?) {
        cancelPendingTap()
        let work = DispatchWorkItem { [self] in
            pendingTap = nil
            // 确认这次抬手是真的：清掉手势状态，别让下一次触摸把它续上
            interpreter.cancel()
            guard let button else { return }
            haptic.impactOccurred(intensity: 1)
            fire(button)
        }
        pendingTap = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tapFireDelay, execute: work)
    }

    private func cancelPendingTap() {
        pendingTap?.cancel()
        pendingTap = nil
    }

    // MARK: - 拖尾采样

    /// 追加一个轨迹采样点：与上一点之间按角度插值，让快速转动下的拖尾依然连续
    private func appendTrailPoint(_ point: TrailPoint) {
        if let last = trailPoints.last {
            let dAngle = WheelDragTracker.shortestDelta(from: last.angle, to: point.angle)
            let steps = max(1, Int(abs(dAngle) / Self.trailInterpolationStep))
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                trailPoints.append(TrailPoint(
                    angle: last.angle + dAngle * t,
                    radius: last.radius + (point.radius - last.radius) * CGFloat(t)
                ))
            }
        } else {
            trailPoints.append(point)
        }
        if trailPoints.count > Self.maxTrailPoints {
            trailPoints.removeFirst(trailPoints.count - Self.maxTrailPoints)
        }
    }

    // MARK: - 长按

    private func scheduleLongPress() {
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: Self.longPressDuration, repeats: false) { _ in
            Task { @MainActor in
                didLongPress = true
                pressed = nil
                haptic.impactOccurred(intensity: 1)
                onLongCenter()
            }
        }
    }

    private func cancelLongPress() {
        longPressTimer?.invalidate()
        longPressTimer = nil
    }

    // MARK: - 几何工具

    private static func angle(of point: CGPoint, from center: CGPoint) -> Double {
        atan2(point.y - center.y, point.x - center.x) * 180 / .pi
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func fire(_ button: WheelButton) {
        switch button {
        case .menu: onMenu()
        case .previous: onPrevious()
        case .next: onNext()
        case .playPause: onPlayPause()
        case .center: onCenter()
        }
    }
}

// MARK: - 旋转拖尾

/// 一次转盘手势的运行状态
///
/// 用 class 而不用 @State 存 struct：转一圈是长时间连续手势，回调里每帧都在改，
/// 引用语义不依赖 View 重建时的值传递，读到的永远是最新的那一份。
final class WheelGestureState {
    /// 点按 / 旋转判定（首次 move 前为 nil）
    var tracker: WheelDragTracker?
    /// 按下位置，用来识别「这是新的一次手势」
    var startLocation: CGPoint?
    /// 按下瞬间落在哪个键上。点按以**按下位置**为准（真机也是按下哪个就是哪个），
    /// 不能看抬手位置——手指转一圈回到原点时会落到别的扇区。
    var startButton: WheelButton?
    /// 22° 步进的累计角度
    var accumulated: Double = 0
    /// 本次手势是否已经产生过旋转（点按判定的第二道保险）
    var didRotate = false
    /// 最近一次的手指位置：用来判断「识别器换了按下点」是不是同一个触摸
    var lastLocation: CGPoint?
    /// 已经收到过结束事件。结束事件可能是假的（识别器被系统中断后又续上），
    /// 所以收尾要延后到确认没有后续事件时才做。
    var ended = false

    /// 是否正在跟踪一次触摸
    var isActive: Bool { tracker != nil }

    /// 当前手势是否处于「点按」范围
    var isTap: Bool { tracker?.isTap ?? true }
    var peakDisplacement: CGFloat? { tracker?.peakDisplacement }

    /// 手势是否已经在跟踪给定的按下点
    func isTracking(startLocation: CGPoint) -> Bool {
        tracker != nil && self.startLocation == startLocation
    }

    func begin(at location: CGPoint, center: CGPoint) {
        tracker = WheelDragTracker(center: center)
        startLocation = location
        accumulated = 0
        didRotate = false
        lastLocation = nil
        ended = false
    }

    func reset() {
        tracker = nil
        startLocation = nil
        startButton = nil
        accumulated = 0
        didRotate = false
        lastLocation = nil
        ended = false
    }
}

/// 拖尾里的一个轨迹点：记录手指当时的角度与半径
private struct TrailPoint: Identifiable {
    let id = UUID()
    let angle: Double
    let radius: CGFloat
}

/// 整条拖尾：一个视图、一次绘制。
///
/// 早先每颗光点是一个带 `RadialGradient` 的 `Circle`，转一圈要连续拖好几秒，
/// 每帧重建几十个渐变视图会把帧率打下去，手感变成「转着转着断了」。
/// Canvas 是立即模式绘制，每帧只画一遍，光点再多也只是几次填充。
private struct TrailCanvas: View {
    let points: [CGPoint]
    let side: CGFloat
    let intensity: Double

    var body: some View {
        Canvas { context, _ in
            guard points.count >= 2 else { return }
            let base = max(5, side * 0.052)
            let intensity = max(0.25, min(1, intensity))
            let count = points.count
            let headIndex = count - 1

            // 彗星光带：沿手指真实路径三层递减柔光，从尾部到头部逐段收窄变亮
            let glow = (
                width: base * (1.3 + 0.3 * intensity),
                color: PodTheme.selectedTop, opacity: 0.10 + 0.10 * intensity,
                from: 0
            )
            let bodyBand = (
                width: base * (0.75 + 0.2 * intensity),
                color: PodTheme.selectedTop, opacity: 0.20 + 0.18 * intensity,
                from: max(0, headIndex - (count * 7) / 10)
            )
            let coreBand = (
                width: base * (0.38 + 0.12 * intensity),
                color: Color(hex: 0xAFC6F2), opacity: 0.45 + 0.35 * intensity,
                from: max(0, headIndex - (count * 4) / 10)
            )
            for band in [glow, bodyBand, coreBand] {
                let path = smoothPath(Array(points[band.from...]))
                context.stroke(path,
                               with: .color(band.color.opacity(band.opacity)),
                               style: StrokeStyle(lineWidth: band.width,
                                                  lineCap: .round, lineJoin: .round))
            }

            // 光点：浅蓝芯、蓝晕、外缘渐隐，叠加出流动的光尘质感。
            // 不掺白色，避免出现零散白点。
            for (index, point) in points.enumerated() {
                // 0 = 最旧（尾）→ 1 = 最新（头）
                let t = Double(index) / Double(headIndex)
                let diameter = base * (0.5 + 0.5 * t) * (0.85 + 0.3 * intensity)
                let opacity = (0.10 + 0.5 * t) * (0.7 + 0.5 * intensity)
                let rect = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2,
                                  width: diameter, height: diameter)
                let shading = GraphicsContext.Shading.radialGradient(
                    Gradient(colors: [
                        Color(hex: 0xAFC6F2).opacity(opacity),
                        PodTheme.selectedTop.opacity(opacity * 0.55),
                        PodTheme.selectedTop.opacity(0),
                    ]),
                    center: point, startRadius: 0, endRadius: diameter / 2
                )
                context.fill(Path(ellipseIn: rect), with: shading)
            }

            // 彗核：手指位置的一颗亮斑，外面套两层递减光晕代替阴影
            // （Canvas 里画阴影比叠两个圆贵得多）
            if let head = points.last {
                let headSize = max(5, side * 0.030) * (0.9 + 0.3 * intensity)
                let glowRadius = headSize / 2 + max(3, side * 0.02)
                let glowRect = CGRect(x: head.x - glowRadius, y: head.y - glowRadius,
                                      width: glowRadius * 2, height: glowRadius * 2)
                let glowShading = GraphicsContext.Shading.radialGradient(
                    Gradient(colors: [
                        PodTheme.selectedTop.opacity(0.9),
                        PodTheme.selectedTop.opacity(0.25),
                        PodTheme.selectedTop.opacity(0),
                    ]),
                    center: head, startRadius: 0, endRadius: glowRadius
                )
                context.fill(Path(ellipseIn: glowRect), with: glowShading)

                let coreRect = CGRect(x: head.x - headSize / 2, y: head.y - headSize / 2,
                                      width: headSize, height: headSize)
                context.fill(Path(ellipseIn: coreRect),
                             with: .color(Color(hex: 0xEAF2FF).opacity(0.95)))
            }
        }
    }
}

/// 把一串坐标点连成平滑二次曲线（中点作为曲线控制点）
private func smoothPath(_ pts: [CGPoint]) -> Path {
    var path = Path()
    guard pts.count >= 2 else { return path }
    path.move(to: pts[0])
    if pts.count == 2 {
        path.addLine(to: pts[1])
    } else {
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2,
                              y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
    }
    return path
}

// MARK: - 刻字图形

/// 圆环扇区：从内半径到外缘的一块（用于按压缩进效果）
struct WheelSector: Shape {
    let startAngle: Angle
    let endAngle: Angle
    let innerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) / 2
        path.addArc(center: center, radius: outerRadius,
                    startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.addArc(center: center, radius: innerRadius,
                    startAngle: endAngle, endAngle: startAngle, clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// 上一首 / 下一首：外侧一根竖线 + 两个紧贴的三角（真 iPod 的 ❙◀◀ / ▶▶❙）。
///
/// 用自绘 Shape 而不用 SF Symbol——SF 的 `backward.fill` 是「竖线 + 单三角」，
/// 真 iPod 是「竖线 + 双三角」，且两个三角之间没有间隙（对照 iPod 转盘矢量图）。
struct SeekGlyph: Shape {
    enum Direction { case backward, forward }
    var direction: Direction

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let barW = rect.width * 0.13
        let barGap = rect.width * 0.04
        let triW = (rect.width - barW - barGap) / 2
        let midY = rect.midY
        let halfH = rect.height / 2

        func addBar(at x: CGFloat) {
            path.addRect(CGRect(x: x, y: rect.minY, width: barW, height: rect.height))
        }

        // apexLeft == true：尖端朝左、底边在右；false：尖端朝右、底边在左
        func addTriangle(left: CGFloat, apexLeft: Bool) {
            if apexLeft {
                path.move(to: CGPoint(x: left, y: midY))
                path.addLine(to: CGPoint(x: left + triW, y: midY - halfH))
                path.addLine(to: CGPoint(x: left + triW, y: midY + halfH))
            } else {
                path.move(to: CGPoint(x: left, y: midY - halfH))
                path.addLine(to: CGPoint(x: left, y: midY + halfH))
                path.addLine(to: CGPoint(x: left + triW, y: midY))
            }
            path.closeSubpath()
        }

        switch direction {
        case .backward:   // ❙◀◀：竖线在左，两个三角尖端朝左、紧贴
            addBar(at: rect.minX)
            addTriangle(left: rect.minX + barW + barGap, apexLeft: true)
            addTriangle(left: rect.minX + barW + barGap + triW, apexLeft: true)
        case .forward:    // ▶▶❙：两个三角尖端朝右、紧贴，竖线在右
            addTriangle(left: rect.minX, apexLeft: false)
            addTriangle(left: rect.minX + triW, apexLeft: false)
            addBar(at: rect.minX + triW * 2 + barGap)
        }
        return path
    }
}

/// 播放 / 暂停：一个三角 + 两条竖线（真 iPod 底部的 ▶❙❙，比例对照转盘矢量图）
struct PlayPauseGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let triW = w * 0.41
        let triGap = w * 0.24
        let barW = w * 0.12
        let barGap = w * 0.11

        // ▶：占满全高的右向三角
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + triW, y: rect.midY))
        path.closeSubpath()

        // ❙❙：两条竖线
        let firstX = rect.minX + triW + triGap
        for i in 0..<2 {
            let x = firstX + CGFloat(i) * (barW + barGap)
            path.addRect(CGRect(x: x, y: rect.minY, width: barW, height: h))
        }
        return path
    }
}
