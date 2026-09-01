import SwiftUI

// MARK: - 路由

enum PodRoute: Hashable {
    case main
    case songs
    case albums
    case albumTracks(Album)
    case artists
    case artistTracks(Artist)
    case playlists
    case playlistTracks(Playlist)
    case favorites
    case genres
    case genreTracks(Genre)
    case search
    case nowPlaying
    case settings
    case connection
    case about
}

/// 导航方向（决定转场动画的推入方向）
enum NavDirection {
    case forward, backward
}

/// iPod 式导航栈（自己维护，因为界面不是标准 NavigationStack 结构）
@MainActor
@Observable
final class PodNavigation {
    var stack: [PodRoute] = []
    private(set) var direction: NavDirection = .forward

    var current: PodRoute { stack.last ?? .main }
    var canGoBack: Bool { !stack.isEmpty }
    /// 用于给转场动画提供稳定的身份标识
    var depth: Int { stack.count }

    func push(_ route: PodRoute) {
        direction = .forward
        stack.append(route)
    }

    func pop() {
        guard !stack.isEmpty else { return }
        direction = .backward
        stack.removeLast()
    }

    func popToRoot() {
        guard !stack.isEmpty else { return }
        direction = .backward
        stack.removeAll()
    }

    func reset(to route: PodRoute) {
        direction = .forward
        stack = [route]
    }
}

// MARK: - 转盘事件

/// 转盘与当前界面的解耦层
///
/// 全局动作（上一首 / 下一首 / 播放暂停 / 返回）由根视图统一绑定；
/// 每个界面只需要在出现时注册自己的「旋转」与「中心键」语义。
@MainActor
@Observable
final class WheelController {
    var onRotate: ((Int) -> Void)?
    /// 连续角度增量（度），列表页用它做像素级跟手滚动
    var onAngle: ((Double) -> Void)?
    var onMenu: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onCenter: (() -> Void)?
    /// 长按中心键：当前界面用它呼出选中项的操作菜单（真 iPod 的交互）
    var onLongCenter: (() -> Void)?

    /// 转盘在 Now Playing 下旋转用于快进快退，这里标记以便显示不同提示
    var isScrubbing = false
}

// MARK: - 菜单界面的转盘绑定

/// 把转盘绑定到菜单：旋转切换选中行，中心键确认，MENU 返回上一级
struct PodWheelBinding: ViewModifier {
    @Environment(WheelController.self) private var wheel
    @Environment(PodNavigation.self) private var nav

    var selected: Binding<Int>
    var count: Int
    var onActivate: (Int) -> Void
    var onMenu: (() -> Void)?
    var onCenter: (() -> Void)?
    var onLongCenter: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: bind)
            .onChange(of: count) { _, _ in bind() }
    }

    private func bind() {
        wheel.isScrubbing = false
        wheel.onLongCenter = onLongCenter
        wheel.onRotate = { [self] delta in
            guard count > 0 else { return }
            var next = selected.wrappedValue + delta
            // 到头停住（iPod 行为：不循环）
            next = max(0, min(count - 1, next))
            selected.wrappedValue = next
        }
        wheel.onCenter = { [self] in
            if let onCenter { onCenter(); return }
            guard count > 0, selected.wrappedValue < count else { return }
            onActivate(selected.wrappedValue)
        }
        wheel.onMenu = { [self] in
            if let onMenu { onMenu() } else { nav.pop() }
        }
    }
}

extension View {
    func podWheel(
        selected: Binding<Int>,
        count: Int,
        onActivate: @escaping (Int) -> Void,
        onMenu: (() -> Void)? = nil,
        onCenter: (() -> Void)? = nil,
        onLongCenter: (() -> Void)? = nil
    ) -> some View {
        modifier(PodWheelBinding(
            selected: selected, count: count,
            onActivate: onActivate, onMenu: onMenu,
            onCenter: onCenter, onLongCenter: onLongCenter
        ))
    }
}
