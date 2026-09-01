import SwiftUI
import UIKit

// MARK: - 菜单项

struct PodMenuItem: Identifiable {
    let id: String
    let title: String
    var subtitleRight: String?
    var subtitleBelow: String?
    var showDisclosure = false
    var isNowPlayingRow = false

    init(id: String? = nil, title: String, subtitleRight: String? = nil,
         subtitleBelow: String? = nil, showDisclosure: Bool = false,
         isNowPlayingRow: Bool = false) {
        self.id = id ?? title
        self.title = title
        self.subtitleRight = subtitleRight
        self.subtitleBelow = subtitleBelow
        self.showDisclosure = showDisclosure
        self.isNowPlayingRow = isNowPlayingRow
    }
}

// MARK: - 机身

/// iPod 正面：屏幕区与转盘区各占独立空间
///
/// 采用真机的分区结构——上方是屏幕，下方是转盘，**两者不重叠**。
/// 转盘不做成浮层：内容一旦能滚到转盘底下，长列表的最后几行就会被圆盘压住，
/// 既不像 iPod 也不好用。
///
/// 屏幕区吃掉除去转盘区之外的全部高度，并保持满宽，所以可视面积仍然远大于
/// 早期那版带机身外壳的 4:3 内嵌屏。
struct PodDevice<Content: View>: View {
    let screen: Content
    let wheel: ClickWheel

    /// 转盘直径：参考真机（转盘直径约为机身宽度的 61.5%），
    /// 并夹在可用区间内，避免小屏挤爆、大屏过长
    private static func wheelDiameter(for size: CGSize) -> CGFloat {
        min(max(min(size.width * 0.62, size.height * 0.32), 170), 280)
    }

    /// 转盘上下留白：**两边取同一个值**，转盘在金属区里垂直居中。
    ///
    /// 曾经上 12、下 60（下边距要跨过 Home Indicator），转盘被顶到区域上半部，
    /// 上下不对称非常扎眼。真机上这两道缝也是大致相等的（103.5mm 机身里，
    /// 屏幕下沿到转盘 ≈ 转盘到机身底边 ≈ 8.7mm），所以这里统一成一个值。
    ///
    /// 下限要跨过 Home Indicator 再留余量，否则转盘会压在系统手势条上；
    /// 上限避免大屏把屏幕区压得过扁。
    private static func wheelEdgePadding(safeBottom: CGFloat) -> CGFloat {
        min(max(safeBottom + 18, 32), 72)
    }

    /// 转盘区总高
    private static func wheelZoneHeight(diameter: CGFloat, safeBottom: CGFloat) -> CGFloat {
        diameter + wheelEdgePadding(safeBottom: safeBottom) * 2
    }


    var body: some View {
        GeometryReader { geo in
            let safeBottom = geo.safeAreaInsets.bottom
            let diameter = Self.wheelDiameter(for: geo.size)
            let zone = Self.wheelZoneHeight(diameter: diameter, safeBottom: safeBottom)
            // 屏幕区至少留 140pt，防止极端小屏被转盘挤没
            let screenHeight = max(140, geo.size.height - zone)

            VStack(spacing: 0) {
                // 屏幕区：满宽、白底
                screen
                    .frame(width: geo.size.width, height: screenHeight)
                    .clipped()

                // 转盘区：拉丝铝机身，与上方白色屏幕区通过一道缝分开
                wheel
                    .frame(width: diameter, height: diameter)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Self.wheelEdgePadding(safeBottom: safeBottom))
                    .background(PodTheme.wheelZoneGradient)
                    .overlay(alignment: .top) {
                        // 屏幕下沿的暗缝 + 金属面顶部高光，两道一起才有「屏幕嵌在
                        // 机身里」的层次，单画一条会显得很平
                        VStack(spacing: 0) {
                            Rectangle()
                                .fill(PodTheme.seamShadow)
                                .frame(height: 1.5)
                            Rectangle()
                                .fill(PodTheme.seamHighlight)
                                .frame(height: 0.5)
                        }
                    }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // 键盘弹出时让系统把整台「iPod」按安全区收缩：屏幕区与转盘区一起
        // 变小、转盘始终露在键盘上方可操作（与真机键盘/外设弹起时一致的
        // 收缩体验）。注意各页面不要再手动按键盘高度让位，否则双重压缩
        // 会把列表压成 0 高度 → 白屏。
        .background(PodTheme.screenBackground.ignoresSafeArea())
    }
}

// MARK: - 屏幕

/// 一块 iPod 屏幕：标题栏 + 内容区
struct PodScreen<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(title: title)
            // 转盘是独立区域而非浮层，所以内容可以放心铺满整块屏幕区，
            // 不需要为转盘预留底部空间。
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .background(PodTheme.screenBackground)
    }
}

// MARK: - 标题栏

struct TitleBar: View {
    let title: String

    var body: some View {
        ZStack {
            PodTheme.titleGradient
            Text(title)
                .font(PodFont.title())
                .foregroundStyle(PodTheme.titleText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 24)
        }
        .frame(height: PodTheme.titleBarHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PodTheme.titleDivider)
                .frame(height: 1)
        }
    }
}

// MARK: - 菜单列表

/// iPod 经典菜单：整行高亮的选中态，转盘驱动 `selected`
struct PodMenuList: View {
    let items: [PodMenuItem]
    @Binding var selected: Int
    var onActivate: (Int) -> Void = { _ in }

    @Environment(WheelController.self) private var wheel

    private var rowHeight: CGFloat { PodTheme.rowHeight }
    /// 与 ClickWheel.stepDegrees 一致：角度 → 像素换算
    private var pixelsPerDegree: CGFloat { rowHeight / 22 }

    /// 当前滚动偏移（pt），由转盘角度/用户拖动直接驱动
    @State private var offset = CGPoint.zero
    /// 上一次我们主动下发的偏移（区分程序滚动与用户拖动）
    @State private var requestedY: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    /// 转盘/拖动引起的选中变化（不再触发点击式滚动动画）
    @State private var wheelDrivenSelection: Int?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    MenuRow(item: item, isSelected: index == selected)
                        .id(index)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = index; onActivate(index) }
                }
            }
            // 探针放在滚动内容内部：其祖先链里一定有底层 UIScrollView
            .background(
                ScrollOffsetAccessor(offset: $offset, requestedY: $requestedY)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            )
        }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { viewportHeight = geo.size.height }
                .onChange(of: geo.size.height) { _, h in viewportHeight = h }
        })
        .onChange(of: offset) { _, newValue in
            let y = newValue.y
            // 我们自己下发的偏移：忽略
            guard abs(y - requestedY) > 0.5 else { return }
            // 用户拖动：跟随手指并同步选中行
            requestedY = y
            syncSelection(from: y)
        }
        .onChange(of: selected) { _, newValue in
            // 用户拖动已驱动过该选中 → 不再重复滚动
            if wheelDrivenSelection == newValue {
                wheelDrivenSelection = nil
                return
            }
            // 转盘步进 / 点击行：把偏移对齐到选中行（不依赖动画，避免跳动）。
            // 角度驱动已在 22°≈1 行时保持对齐，这里只做微小纠偏
            guard items.indices.contains(newValue) else { return }
            let y = centeredY(for: newValue)
            requestedY = y
            offset = CGPoint(x: 0, y: y)
        }
        .onAppear {
            wheel.onAngle = { [self] delta in handleAngle(delta) }
        }
        .onDisappear {
            wheel.onAngle = nil
        }
    }

    /// 转盘角度 → 像素级滚动（无动画、无滞后，像拖动一样跟手）。
    /// 选中行由 ClickWheel 的 22° 步进（onRotate）推进，二者天然对齐
    private func handleAngle(_ delta: Double) {
        guard !items.isEmpty else { return }
        let maxY = max(0, CGFloat(items.count) * rowHeight - max(0, viewportHeight))
        let y = min(max(0, offset.y + CGFloat(delta) * pixelsPerDegree), maxY)
        requestedY = y
        offset = CGPoint(x: 0, y: y)
    }

    private func syncSelection(from y: CGFloat) {
        let center = max(0, (viewportHeight - rowHeight) / 2)
        let index = Int(((y + center) / rowHeight).rounded())
        guard items.indices.contains(index), index != selected else { return }
        wheelDrivenSelection = index
        selected = index
    }

    /// 让第 index 行居中的内容偏移（含首尾夹紧）
    private func centeredY(for index: Int) -> CGFloat {
        let center = max(0, (viewportHeight - rowHeight) / 2)
        let y = CGFloat(index) * rowHeight - center
        let maxY = max(0, CGFloat(items.count) * rowHeight - max(0, viewportHeight))
        return min(max(0, y), maxY)
    }
}

/// 访问 SwiftUI ScrollView 底层 UIScrollView 的偏移（iOS 17 无 ScrollPosition.position）。
/// 转盘/程序侧直接 setContentOffset（无动画），实现像素级连续滚动；用户拖动时
/// 轮询读回偏移并同步绑定。
private struct ScrollOffsetAccessor: UIViewRepresentable {
    @Binding var offset: CGPoint
    /// 最近一次程序下发的偏移（用于区分程序滚动与用户拖动）
    @Binding var requestedY: CGFloat

    func makeUIView(context: Context) -> ProbeView {
        ProbeView(offset: $offset, requestedY: $requestedY)
    }
    func updateUIView(_ view: ProbeView, context: Context) {
        view.push(offset)
    }

    final class ProbeView: UIView {
        private var offsetBinding: Binding<CGPoint>
        private var requestedBinding: Binding<CGFloat>
        private weak var scrollView: UIScrollView?
        private var lastApplied: CGPoint?
        private var timer: Timer?

        init(offset: Binding<CGPoint>, requestedY: Binding<CGFloat>) {
            self.offsetBinding = offset
            self.requestedBinding = requestedY
            super.init(frame: .zero)
            isHidden = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            timer?.invalidate()
            timer = nil
            guard window != nil else { return }
            findScrollView()
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                self?.poll()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }

        private func findScrollView() {
            var v: UIView? = superview
            while let s = v {
                if let sv = s as? UIScrollView {
                    scrollView = sv
                    return
                }
                v = s.superview
            }
        }

        /// 程序侧设置偏移：直接 setContentOffset，无动画
        func push(_ point: CGPoint) {
            guard let sv = scrollView, lastApplied != point else { return }
            lastApplied = point
            sv.setContentOffset(point, animated: false)
        }

        /// 轮询读回偏移：用户拖动时同步到绑定
        private func poll() {
            guard let sv = scrollView else {
                findScrollView()
                return
            }
            let p = sv.contentOffset
            if lastApplied == nil || abs(p.x - lastApplied!.x) > 0.5 || abs(p.y - lastApplied!.y) > 0.5 {
                // 与程序下发的偏移一致 → 忽略（避免反馈循环）
                if abs(p.y - requestedBinding.wrappedValue) <= 0.5 { return }
                lastApplied = p
                offsetBinding.wrappedValue = p
            }
        }
    }
}

struct MenuRow: View {
    let item: PodMenuItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            if item.isNowPlayingRow {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .bold))
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(PodFont.row(selected: isSelected))
                    .lineLimit(1)
                if let below = item.subtitleBelow, !below.isEmpty {
                    Text(below)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .opacity(0.75)
                }
            }

            Spacer(minLength: 4)

            if let right = item.subtitleRight, !right.isEmpty {
                Text(right)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .opacity(0.8)
            }

            if item.showDisclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(0.85)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: PodTheme.rowHeight)
        .foregroundStyle(isSelected ? PodTheme.selectedText : PodTheme.rowText)
        .background {
            if isSelected {
                PodTheme.selectedGradient
            } else {
                Color.clear
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PodTheme.rowSeparator)
                .frame(height: 0.5)
                .opacity(isSelected ? 0 : 1)
        }
        .clipShape(Rectangle())
    }
}

// MARK: - 空状态 / 加载

struct PodMessageView: View {
    let text: String
    var systemImage: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 26))
                    .foregroundStyle(PodTheme.sectionHeader)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(PodTheme.rowSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PodLoadingView: View {
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(PodTheme.rowSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
