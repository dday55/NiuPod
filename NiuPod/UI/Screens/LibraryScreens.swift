import SwiftUI

// MARK: - 歌曲

struct SongsScreen: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        TrackListScreen(
            title: "歌曲",
            tracks: library.songs,
            isLoading: library.isLoading,
            emptyMessage: library.errorMessage ?? "暂无歌曲"
        )
    }
}

// MARK: - 收藏

struct FavoritesScreen: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        TrackListScreen(
            title: "收藏",
            tracks: library.favorites,
            isLoading: library.isLoading,
            emptyMessage: "还没有收藏歌曲\n在任意曲目列表长按中心键可收藏"
        )
    }
}

// MARK: - 专辑

struct AlbumsScreen: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PodNavigation.self) private var nav
    @State private var selected = 0

    private var items: [PodMenuItem] {
        library.albums.map {
            PodMenuItem(id: $0.guid, title: $0.name,
                        subtitleRight: $0.trackCount.map { "\($0) 首" },
                        showDisclosure: true)
        }
    }

    var body: some View {
        PodScreen(title: "专辑") {
            content
        }
        .podWheel(selected: $selected, count: items.count) { index in
            nav.push(.albumTracks(library.albums[index]))
        }
    }

    private var content: some View {
        Group {
            if library.isLoading, library.albums.isEmpty {
                PodLoadingView(text: "载入专辑…")
            } else if library.albums.isEmpty {
                PodMessageView(text: library.errorMessage ?? "暂无专辑", systemImage: "square.stack")
            } else {
                PodMenuList(items: items, selected: $selected) { index in
                    nav.push(.albumTracks(library.albums[index]))
                }
            }
        }
    }
}

// MARK: - 歌手

struct ArtistsScreen: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PodNavigation.self) private var nav
    @State private var selected = 0

    private var items: [PodMenuItem] {
        library.artists.map {
            PodMenuItem(id: $0.guid, title: $0.name,
                        subtitleRight: $0.trackCount.map { "\($0) 首" },
                        showDisclosure: true)
        }
    }

    var body: some View {
        PodScreen(title: "歌手") {
            content
        }
        .podWheel(selected: $selected, count: items.count) { index in
            nav.push(.artistTracks(library.artists[index]))
        }
    }

    private var content: some View {
        Group {
            if library.isLoading, library.artists.isEmpty {
                PodLoadingView(text: "载入歌手…")
            } else if library.artists.isEmpty {
                PodMessageView(text: library.errorMessage ?? "暂无歌手", systemImage: "person.2")
            } else {
                PodMenuList(items: items, selected: $selected) { index in
                    nav.push(.artistTracks(library.artists[index]))
                }
            }
        }
    }
}

// MARK: - 歌单

struct PlaylistsScreen: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PodNavigation.self) private var nav
    @State private var selected = 0

    private var items: [PodMenuItem] {
        library.playlists.map {
            PodMenuItem(id: $0.guid, title: $0.name,
                        subtitleRight: "\($0.trackCount) 首",
                        showDisclosure: true)
        }
    }

    var body: some View {
        PodScreen(title: "歌单") {
            content
        }
        .podWheel(selected: $selected, count: items.count) { index in
            nav.push(.playlistTracks(library.playlists[index]))
        }
    }

    private var content: some View {
        Group {
            if library.isLoading, library.playlists.isEmpty {
                PodLoadingView(text: "载入歌单…")
            } else if library.playlists.isEmpty {
                PodMessageView(text: library.errorMessage ?? "暂无歌单", systemImage: "music.note.list")
            } else {
                PodMenuList(items: items, selected: $selected) { index in
                    nav.push(.playlistTracks(library.playlists[index]))
                }
            }
        }
    }
}

// MARK: - 风格

struct GenresScreen: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PodNavigation.self) private var nav
    @State private var selected = 0

    private var items: [PodMenuItem] {
        library.genres.map {
            PodMenuItem(id: $0.guid, title: $0.name,
                        subtitleRight: "\($0.trackCount) 首",
                        showDisclosure: true)
        }
    }

    var body: some View {
        PodScreen(title: "风格") {
            content
        }
        .podWheel(selected: $selected, count: items.count) { index in
            nav.push(.genreTracks(library.genres[index]))
        }
    }

    private var content: some View {
        Group {
            if library.isLoading, library.genres.isEmpty {
                PodLoadingView(text: "载入风格…")
            } else if library.genres.isEmpty {
                PodMessageView(text: library.errorMessage ?? "暂无风格", systemImage: "guitars")
            } else {
                PodMenuList(items: items, selected: $selected) { index in
                    nav.push(.genreTracks(library.genres[index]))
                }
            }
        }
    }
}

// MARK: - 曲目列表（所有曲目列表共用）

/// 曲目列表：转盘选歌 + 中心键播放 + **长按中心键弹出操作菜单**
///
/// 收藏/取消收藏的入口以前只在「正在播放 → 选项」里，收藏列表甚至没有任何
/// 移除方式。现在统一在这里长按中心键呼出菜单，所有曲目列表页都覆盖了。
struct PodTrackList: View {
    let title: String
    let tracks: [Track]
    var isLoading = false
    var emptyMessage = "暂无歌曲"

    @Environment(AudioPlayer.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(PodNavigation.self) private var nav
    @Environment(WheelController.self) private var wheel

    @State private var selected = 0
    /// 非空 = 操作菜单已打开
    @State private var actionTrack: Track?
    @State private var actionIndex = 0

    var body: some View {
        ZStack {
            PodScreen(title: title) { content }

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
        .onChange(of: tracks.count) { _, _ in
            if selected >= tracks.count { selected = max(0, tracks.count - 1) }
            bindWheel()
        }
        // 菜单开合要重新绑定转盘，否则转盘还停留在「列表滚动」语义上
        .onChange(of: actionTrack?.guid ?? "") { _, _ in bindWheel() }
    }

    // MARK: 内容

    private var items: [PodMenuItem] {
        tracks.map { track in
            PodMenuItem(id: track.guid, title: track.title,
                        subtitleRight: (track.duration ?? 0).durationText,
                        subtitleBelow: "\(track.artistName) — \(track.album.name)")
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if isLoading, tracks.isEmpty {
                PodLoadingView(text: "载入中…")
            } else if tracks.isEmpty {
                PodMessageView(text: emptyMessage, systemImage: "music.note")
            } else {
                PodMenuList(items: items, selected: $selected) { index in play(index) }
            }
            if !tracks.isEmpty { hintBar }
        }
    }

    /// 长按呼出菜单是个隐藏入口，没有提示等于没有
    private var hintBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 9))
            Text("长按中心键 = 播放 / 收藏")
                .font(.system(size: 10))
        }
        .foregroundStyle(PodTheme.sectionHeader)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(PodTheme.statusBarBottom)
        .overlay(alignment: .top) {
            Rectangle().fill(PodTheme.rowSeparator).frame(height: 0.5)
        }
    }

    // MARK: 转盘

    private func bindWheel() {
        wheel.isScrubbing = false

        guard actionTrack == nil else {
            // 菜单模式：转盘选行，中心键执行，MENU / 再长按都关闭
            let count = 3
            wheel.onRotate = { [self] delta in
                actionIndex = max(0, min(count - 1, actionIndex + delta))
            }
            wheel.onCenter = { [self] in performAction(actionIndex) }
            wheel.onMenu = { [self] in actionTrack = nil }
            wheel.onLongCenter = { [self] in actionTrack = nil }
            return
        }

        // 列表模式
        wheel.onRotate = { [self] delta in
            guard !tracks.isEmpty else { return }
            selected = max(0, min(tracks.count - 1, selected + delta))
        }
        wheel.onCenter = { [self] in
            guard tracks.indices.contains(selected) else { return }
            play(selected)
        }
        wheel.onMenu = { [self] in nav.pop() }
        wheel.onLongCenter = { [self] in
            guard tracks.indices.contains(selected) else { return }
            actionIndex = 0
            actionTrack = tracks[selected]
        }
    }

    // MARK: 动作

    private func play(_ index: Int) {
        player.playQueue(tracks, startingAt: index)
        nav.push(.nowPlaying)
    }

    private func performAction(_ index: Int) {
        guard let track = actionTrack else { return }
        switch index {
        case 0:
            actionTrack = nil
            play(tracks.firstIndex(of: track) ?? selected)
        case 1:
            Task { await library.toggleFavorite(track) }
            actionTrack = nil
        default:
            actionTrack = nil
        }
    }
}

// MARK: - 二级曲目列表（异步载入）

/// 通用异步曲目列表：进入时按 guid 拉取，拿到数据后交给 `PodTrackList`
struct AsyncTrackListScreen: View {
    let title: String
    let loader: () async -> [Track]

    @State private var tracks: [Track] = []
    @State private var isLoading = true

    var body: some View {
        PodTrackList(title: title, tracks: tracks, isLoading: isLoading)
            .task { await load() }
    }

    private func load() async {
        isLoading = true
        tracks = await loader()
        isLoading = false
    }
}

// MARK: - 曲目列表（数据已就绪）

struct TrackListScreen: View {
    let title: String
    let tracks: [Track]
    var isLoading = false
    var emptyMessage = "暂无歌曲"

    init(title: String, tracks: [Track], isLoading: Bool = false, emptyMessage: String = "暂无歌曲") {
        self.title = title
        self.tracks = tracks
        self.isLoading = isLoading
        self.emptyMessage = emptyMessage
    }

    var body: some View {
        PodTrackList(title: title, tracks: tracks,
                     isLoading: isLoading, emptyMessage: emptyMessage)
    }
}
