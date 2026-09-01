import SwiftUI

/// 正在播放
///
/// 转盘语义（与 iPod 实机一致地紧凑）：
/// - 旋转：快进 / 快退（每步 5 秒）
/// - 中心键：在「封面 / 歌词」两层显示之间切换
/// - 四区：MENU 返回、◀◀ 上一首、▶▶ 下一首、▶❙❙ 播放暂停
struct NowPlayingView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(WheelController.self) private var wheel
    @Environment(PodNavigation.self) private var nav

    /// 0 = 封面，1 = 歌词（只保留两层交互）
    @State private var displayMode = 0

    /// 非空 = 曲目操作菜单已打开（长按中心键呼出）
    @State private var actionTrack: Track?
    @State private var actionIndex = 0

    var body: some View {
        ZStack {
            PodScreen(title: screenTitle) {
                VStack(spacing: 0) {
                    headerRow
                    Divider().background(PodTheme.rowSeparator)
                    contentArea
                }
            }

            if let track = actionTrack {
                TrackActionMenu(
                    track: track,
                    isFavorite: library.isFavorite(track),
                    onSelect: { index in performAction(index) },
                    selected: $actionIndex,
                    onClose: { actionTrack = nil }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: actionTrack?.guid ?? "")
        .onAppear(perform: bindWheel)
        // 菜单开合要重新绑定转盘，否则转盘还停留在「封面/歌词切换」语义上
        .onChange(of: actionTrack?.guid ?? "") { _, _ in bindWheel() }
    }

    /// 标题跟随播放状态：播放中 = 正在播放，暂停 = 已暂停播放，停止/无曲目 = 未在播放
    private var screenTitle: String {
        guard player.currentTrack != nil else { return "未在播放" }
        return player.isPlaying ? "正在播放" : "已暂停播放"
    }

    // MARK: - 顶部：数量 + 播放模式

    private var headerRow: some View {
        HStack(spacing: 8) {
            // 数量：当前 / 总数
            HStack(spacing: 3) {
                Text("\(player.queue.isEmpty ? 0 : player.index + 1)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("/")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(0.55)
                Text("\(player.queue.count)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .opacity(0.75)
            }
            Spacer()
            if player.isLoading {
                ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
            }
            // 播放顺序：🔀 亮起 = 随机，熄灭 = 顺序（二选一，不会同时激活）
            modeBadge(icon: "shuffle",
                      title: player.shuffle ? "随机" : "顺序",
                      active: player.shuffle,
                      label: player.shuffle ? "随机播放（已开启）" : "随机播放（已关闭）") {
                player.setShuffle(!player.shuffle, orderedQueue: player.queue)
            }
            // 循环方式：🔁 亮起 = 循环，🔂 亮起 = 单曲，熄灭 = 关闭循环
            modeBadge(icon: player.repeatMode.symbolName,
                      title: player.repeatMode == .one ? "单曲" : "循环",
                      active: player.repeatMode != .off,
                      label: repeatAccessibilityLabel) {
                cycleRepeatMode()
            }
        }
        .foregroundStyle(PodTheme.rowSecondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
    }

    private var repeatAccessibilityLabel: String {
        switch player.repeatMode {
        case .off: return "循环（关闭）"
        case .all: return "列表循环"
        case .one: return "单曲循环"
        }
    }

    private func cycleRepeatMode() {
        let all = RepeatMode.allCases
        player.repeatMode = all[(all.firstIndex(of: player.repeatMode)! + 1) % all.count]
    }

    /// 模式胶囊按钮：图标 + 固定两字短标签（随机/顺序、循环/单曲），
    /// 激活时蓝渐变 + 白字，未激活时浅灰底。短标签保证两个胶囊宽度一致，不显凌乱。
    private func modeBadge(icon: String, title: String, active: Bool, label: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                Capsule().fill(
                    active
                        ? AnyShapeStyle(PodTheme.selectedGradient)
                        : AnyShapeStyle(Color(hex: 0xE9EBEE))
                )
            )
            .foregroundStyle(active ? Color.white : PodTheme.rowSecondary)
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: active ? 0.6 : 0)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - 内容区（封面 / 歌词 两层）

    @ViewBuilder
    private var contentArea: some View {
        if displayMode == 1 {
            lyricsDisplay
        } else {
            progressDisplay
        }
    }

    // MARK: 封面模式

    /// 封面为视觉主体：大封面居中，曲目信息排在下方，进度条沉底。
    private var progressDisplay: some View {
        GeometryReader { geo in
            // 封面随屏幕自适应：约半屏宽，夹在 120~210 之间
            let coverSize = min(max(geo.size.width * 0.46, 120), 210)
            VStack(spacing: 0) {
                Spacer(minLength: 2)

                PodArtwork(coverId: player.currentTrack?.coverId
                           ?? player.currentTrack?.album.coverId,
                           size: coverSize)

                VStack(spacing: 3) {
                    Text(player.currentTrack?.title ?? "未在播放")
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(player.currentTrack?.artistName ?? "—")
                        .font(.system(size: 13))
                        .foregroundStyle(PodTheme.rowSecondary)
                        .lineLimit(1)
                    Text(player.currentTrack?.album.name ?? "—")
                        .font(.system(size: 13))
                        .foregroundStyle(PodTheme.rowSecondary)
                        .lineLimit(1)
                }
                .padding(.top, 10)

                // 播放失败时给出可见提示（真机上「看似在播但没声音」大多能在这里看到原因）
                if let error = player.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 0.72, green: 0.18, blue: 0.18))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.top, 6)
                }

                Spacer(minLength: 6)

                VStack(spacing: 3) {
                    ProgressBar(progress: progress, isLoading: player.isLoading) { p in
                        player.seek(to: p * total)
                    }
                    HStack {
                        Text("-\(remaining.mmss)")
                        Spacer()
                        Text(elapsed.mmss)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PodTheme.rowSecondary)
                }

                hintRow
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 12)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nowPlayingCover")
    }

    // MARK: 歌词模式

    private var lyricsDisplay: some View {
        Group {
            if player.currentLyrics.isEmpty {
                PodMessageView(text: "这首歌暂无歌词", systemImage: "quote.bubble")
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("nowPlayingLyrics")
            } else {
                LyricScrollView(
                    lines: player.currentLyrics,
                    currentIndex: player.currentLyricIndex,
                    elapsed: player.currentTime
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("nowPlayingLyrics")
            }
        }
    }

    private var hintRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 10))
            Text("转盘 = 快进/快退 · 中心键 = 封面/歌词 · 长按 = 菜单")
                .font(.system(size: 11))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(PodTheme.sectionHeader)
    }

    // MARK: - 转盘绑定

    private func bindWheel() {
        wheel.isScrubbing = true

        guard actionTrack == nil else {
            // 菜单模式：转盘选行，中心键执行，MENU / 再长按都关闭
            wheel.isScrubbing = false
            let count = 3
            wheel.onRotate = { [self] delta in
                actionIndex = max(0, min(count - 1, actionIndex + delta))
            }
            wheel.onCenter = { [self] in performAction(actionIndex) }
            wheel.onMenu = { [self] in actionTrack = nil }
            wheel.onLongCenter = { [self] in actionTrack = nil }
            return
        }

        // 封面/歌词层：旋转快进快退，中心键切换显示，长按呼出曲目菜单
        wheel.onMenu = { nav.pop() }
        wheel.onRotate = { [self] delta in
            player.seek(by: Double(delta) * 5)
        }
        wheel.onCenter = { [self] in
            displayMode = displayMode == 1 ? 0 : 1
        }
        wheel.onLongCenter = { [self] in
            guard let track = player.currentTrack else { return }
            actionIndex = 0
            actionTrack = track
        }
    }

    // MARK: - 曲目操作菜单

    private func performAction(_ index: Int) {
        guard let track = actionTrack else { return }
        switch index {
        case 0:
            actionTrack = nil
            player.play()
        case 1:
            actionTrack = nil
            Task { await library.toggleFavorite(track) }
        default:
            actionTrack = nil
        }
        bindWheel()
    }

    // MARK: - 计算属性

    private var elapsed: Double { player.currentTime }
    private var total: Double { player.duration > 0 ? player.duration : player.currentTrack?.durationSeconds ?? 0 }
    private var remaining: Double { max(0, total - elapsed) }
    private var progress: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, elapsed / total))
    }
}

// MARK: - 进度条

struct ProgressBar: View {
    let progress: Double
    var isLoading: Bool = false
    var onSeek: ((Double) -> Void)? = nil

    @State private var dragProgress: Double?
    @State private var isDragging = false

    /// 拖动时以手指位置为准，松手才真正 seek
    private var displayed: Double {
        min(1, max(0, dragProgress ?? progress))
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let trackHeight: CGFloat = 6
            let knob: CGFloat = 16
            let travel: CGFloat = max(0, width - knob)
            let clamped = displayed

            ZStack(alignment: .leading) {
                // 轨道
                Capsule()
                    .fill(Color(hex: 0xE2E4E7))
                    .frame(width: width, height: trackHeight)

                // 已播放（填充到滑块中心，不盖住滑块）
                Capsule()
                    .fill(PodTheme.selectedGradient)
                    .frame(width: max(0, travel * clamped) + knob / 2, height: trackHeight)

                // 滑块
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(PodTheme.selectedBottom, lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.18), radius: 1.5, y: 0.5)
                    .frame(width: knob, height: knob)
                    .offset(x: travel * clamped)
                    .opacity(isLoading && !isDragging ? 0.5 : 1)
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragProgress = min(1, max(0, value.location.x / width))
                        isDragging = true
                    }
                    .onEnded { value in
                        onSeek?(min(1, max(0, value.location.x / width)))
                        dragProgress = nil
                        isDragging = false
                    }
            )
            // 播放中平滑跟进；拖动时禁用动画，让滑块跟手
            .animation(isDragging ? nil : .linear(duration: 0.18), value: displayed)
        }
        .frame(height: 24)
    }
}

// MARK: - 封面

struct PodArtwork: View {
    let coverId: String?
    var size: CGFloat = 74

    @Environment(Session.self) private var session
    @State private var image: UIImage?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: 0xEDEEF0))
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.3))
                    .foregroundStyle(Color(hex: 0xB6BAC0))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
        .task(id: coverId) { await load() }
    }

    private func load() async {
        image = await ArtworkLoader.image(
            for: coverId, using: FeiNiuClient(credentials: session.credentials)
        )
    }
}
