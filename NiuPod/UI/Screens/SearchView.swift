import SwiftUI

/// 搜索页
///
/// iPod 没有键盘，这里的输入框放在标题栏下方（唯一的例外），
/// 结果仍用转盘 + 菜单交互。
struct SearchView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AudioPlayer.self) private var player
    @Environment(PodNavigation.self) private var nav
    @Environment(WheelController.self) private var wheel

    @State private var keyword = ""
    @State private var results = SearchResults.empty
    @State private var isSearching = false
    @State private var selected = 0
    @FocusState private var isFocused: Bool
    /// 输入防抖任务：停止输入约 0.45 秒后才真正发起搜索
    @State private var debounceTask: Task<Void, Never>?
    /// 搜索代次：只采纳最后一次输入对应的结果，避免旧请求覆盖新结果
    @State private var searchGeneration = 0

    private enum Item {
        case track(Track)
        case album(Album)
        case artist(Artist)

        var id: String {
            switch self {
            case .track(let t): "t-\(t.guid)"
            case .album(let a): "a-\(a.guid)"
            case .artist(let a): "r-\(a.guid)"
            }
        }
    }

    private var items: [Item] {
        results.tracks.map(Item.track)
            + results.albums.map(Item.album)
            + results.artists.map(Item.artist)
    }

    var body: some View {
        PodScreen(title: "搜索") {
            VStack(spacing: 0) {
                searchField
                Divider().background(PodTheme.rowSeparator)
                content
            }
        }
        .podWheel(selected: $selected, count: items.count) { index in
            activate(at: index)
        }
        .onChange(of: results.tracks.count + results.albums.count + results.artists.count) { _, newCount in
            if selected >= newCount { selected = max(0, newCount - 1) }
        }
        // 输入即搜索：每次输入变化都重启防抖计时，停止输入后自动检索
        .onChange(of: keyword) { _, _ in
            scheduleSearch()
        }
        .onDisappear {
            isFocused = false
            debounceTask?.cancel()
            debounceTask = nil
        }
    }

    // MARK: - 防抖搜索

    /// 输入防抖：取消上一次未触发的任务，关键词为空立即清空，
    /// 否则等 0.45 秒没有新输入再执行搜索。
    private func scheduleSearch() {
        debounceTask?.cancel()
        debounceTask = nil
        let kw = keyword.trimmed
        guard !kw.isEmpty else {
            searchGeneration += 1
            results = .empty
            isSearching = false
            return
        }
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            debounceTask = nil
            // 直接执行搜索，不经过 runSearch 的「取消防抖」——
            // 否则会把自己 cancel 掉，导致网络请求立刻被取消报「已取消」
            await performSearch()
        }
    }

    /// 真正执行搜索（不做任何取消，避免自杀）
    private func performSearch() async {
        let kw = keyword.trimmed
        guard !kw.isEmpty else {
            searchGeneration += 1
            results = .empty
            isSearching = false
            return
        }
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        let newResults = await library.search(kw)
        // 输入已变化 / 已有更新的搜索 → 丢弃这次结果
        guard generation == searchGeneration, kw == keyword.trimmed else { return }
        results = newResults
        isSearching = false
        selected = 0
    }

    /// 键盘搜索键：立即搜索（先取消挂起的防抖任务，再执行）
    private func runSearch() async {
        debounceTask?.cancel()
        debounceTask = nil
        await performSearch()
    }

    // MARK: - 输入

    private var searchField: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(PodTheme.rowSecondary)
                TextField("歌曲 / 专辑 / 歌手", text: $keyword)
                    .font(.system(size: 12))
                    .focused($isFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit {
                        Task { await runSearch() }
                        // 按键盘「搜索」才收起键盘，转盘浏览时保持键盘弹出
                        isFocused = false
                    }
                if !keyword.isEmpty {
                    Button { keyword = ""; results = .empty } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(PodTheme.rowSecondary)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 30)
        .background(Color(hex: 0xF2F3F5))
        // 整条搜索框都可点：TextField 原生只响应文字区，其余位置
        // 由外层容器接住并程序化聚焦
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }

    // MARK: - 结果

    private var content: some View {
        Group {
            if isSearching {
                PodLoadingView(text: "搜索中…")
            } else if items.isEmpty {
                PodMessageView(
                    text: keyword.trimmed.isEmpty ? "输入关键词即可搜索" : "没有找到结果",
                    systemImage: keyword.trimmed.isEmpty ? "magnifyingglass" : "exclamationmark.magnifyingglass"
                )
            } else {
                PodMenuList(items: menuItems, selected: $selected) { index in
                    activate(at: index)
                }
            }
        }
    }

    private var menuItems: [PodMenuItem] {
        items.map { item in
            switch item {
            case .track(let t):
                PodMenuItem(id: "t-\(t.guid)", title: t.title,
                            subtitleRight: (t.duration ?? 0).durationText,
                            subtitleBelow: "\(t.artistName) — \(t.album.name)")
            case .album(let a):
                PodMenuItem(id: "a-\(a.guid)", title: a.name,
                            subtitleRight: "专辑", showDisclosure: true)
            case .artist(let a):
                PodMenuItem(id: "r-\(a.guid)", title: a.name,
                            subtitleRight: "歌手", showDisclosure: true)
            }
        }
    }

    // MARK: - 动作

    /// 激活结果行。先做越界保护（搜索结果是异步更新的，索引可能已过期），
    /// 再按类型处理。
    private func activate(at index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        switch item {
        case .track(let track):
            // 优先在整个曲库中定位并播放：搜索列表最多只有 30 首，直接拿它当
            // 播放队列会把用户原来的播放列表顶掉，变成一段不完整的「越界」列表。
            // 曲库里能找到就按完整曲库队列播；找不到（例如搜索接口返回了曲库里
            // 没有的条目）才退回用搜索结果列表。
            if let libraryIndex = library.songs.firstIndex(where: { $0.guid == track.guid }) {
                player.playQueue(library.songs, startingAt: libraryIndex)
            } else {
                player.playQueue(results.tracks,
                                 startingAt: results.tracks.firstIndex(of: track) ?? 0)
            }
            nav.push(.nowPlaying)
        case .album(let album):
            nav.push(.albumTracks(album))
        case .artist(let artist):
            nav.push(.artistTracks(artist))
        }
    }
}
