import Foundation

/// 音乐库数据（歌曲 / 专辑 / 歌手 / 歌单 / 风格 / 收藏）
///
/// 登录后一次性拉取全量（飞牛单个接口支持大 size，个人音乐库通常几千首，
/// 一次拉完比分页更省事，也便于 iPod 式「滚动即达」的浏览体验）。
@MainActor
@Observable
final class LibraryStore {
    var songs: [Track] = []
    var albums: [Album] = []
    var artists: [Artist] = []
    var playlists: [Playlist] = []
    var genres: [Genre] = []
    var favorites: [Track] = []

    var isLoading = false
    var errorMessage: String?
    var lastLoadedAt: Date?

    private var loadTask: Task<Void, Never>?

    /// 凭据由外部注入，保证登录/重连后立刻生效
    var credentialsProvider: (() -> Credentials)?
    var onUnauthorized: (() -> Void)?
    /// 演示模式：数据来自本地占位内容
    var isDemo = false

    func reload(force: Bool = false) {
        if isDemo { loadDemo(); return }
        if !force, !songs.isEmpty, let last = lastLoadedAt, Date().timeIntervalSince(last) < 60 {
            return
        }
        loadTask?.cancel()
        loadTask = Task { await load() }
    }

    private func loadDemo() {
        loadTask?.cancel()
        songs = DemoData.tracks
        albums = DemoData.albums
        artists = DemoData.artists
        playlists = DemoData.playlists
        genres = DemoData.genres
        favorites = DemoData.favorites
        lastLoadedAt = Date()
        isLoading = false
        errorMessage = nil
    }

    private func load() async {
        guard let creds = credentialsProvider?(), creds.isValid else {
            errorMessage = "未连接"
            return
        }
        isLoading = true
        errorMessage = nil
        let client = FeiNiuClient(credentials: creds)

        do {
            // 并发拉取，任一失败不拖垮整体
            // 必须用全量拉取：服务端 size 有上限（约 50），只拉第一页会漏掉大部分曲目
            async let t = client.allTracks()
            async let a = client.allAlbums()
            async let ar = client.allArtists()
            async let p = client.allPlaylists()
            async let g = client.allGenres()
            async let f = client.allFavorites()

            let (tracks, albs, arts, pls, gns, favs) = try await (t, a, ar, p, g, f)

            guard !Task.isCancelled else { isLoading = false; return }

            // 格式不支持的曲目（APE/WMA/OGG…）真机播不了，直接过滤，不进入曲库
            songs = tracks.filter(\.isPlayable)
            albums = albs
            artists = arts
            playlists = pls
            genres = gns
            favorites = favs.filter(\.isPlayable)
            lastLoadedAt = Date()
            isLoading = false
            Log.info("[Library] 载入 \(songs.count) 首 / \(albums.count) 专辑 / \(artists.count) 歌手 / \(playlists.count) 歌单")
        } catch {
            if case FeiNiuError.unauthorized = error {
                onUnauthorized?()
                errorMessage = "登录已失效，正在重新登录…"
            } else {
                errorMessage = error.localizedDescription
            }
            isLoading = false
            Log.error("[Library] 载入失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 子列表

    func tracks(ofAlbum guid: String) async -> [Track] {
        if isDemo { return DemoData.tracks.filter { $0.album.guid == guid } }
        guard let creds = credentialsProvider?(), creds.isValid else { return [] }
        do {
            return try await FeiNiuClient(credentials: creds).allAlbumTracks(guid: guid).filter(\.isPlayable)
        } catch {
            Log.error("[Library] 专辑曲目失败：\(error.localizedDescription)")
            return []
        }
    }

    func tracks(ofArtist guid: String) async -> [Track] {
        if isDemo { return DemoData.tracks.filter { $0.artists.contains { $0.guid == guid } } }
        guard let creds = credentialsProvider?(), creds.isValid else { return [] }
        do {
            return try await FeiNiuClient(credentials: creds).allArtistTracks(guid: guid).filter(\.isPlayable)
        } catch {
            Log.error("[Library] 歌手曲目失败：\(error.localizedDescription)")
            return []
        }
    }

    func tracks(ofPlaylist guid: String) async -> [Track] {
        if isDemo {
            // 演示歌单：按名字取固定切片，保证点进去有内容
            let all = DemoData.tracks
            switch guid {
            case DemoData.playlists[0].guid: return Array(all.filter { $0.year ?? 0 >= 2022 })
            case DemoData.playlists[1].guid: return Array(all.filter { $0.album.name == "晨间练习" })
            default: return Array(all.shuffled().prefix(5))
            }
        }
        guard let creds = credentialsProvider?(), creds.isValid else { return [] }
        do {
            return try await FeiNiuClient(credentials: creds).allPlaylistTracks(guid: guid).filter(\.isPlayable)
        } catch {
            Log.error("[Library] 歌单曲目失败：\(error.localizedDescription)")
            return []
        }
    }

    func tracks(ofGenre guid: String) async -> [Track] {
        if isDemo { return Array(DemoData.tracks.shuffled().prefix(8)) }
        guard let creds = credentialsProvider?(), creds.isValid else { return [] }
        do {
            return try await FeiNiuClient(credentials: creds).allGenreTracks(guid: guid).filter(\.isPlayable)
        } catch {
            Log.error("[Library] 风格曲目失败：\(error.localizedDescription)")
            return []
        }
    }

    func search(_ keyword: String) async -> SearchResults {
        let kw = keyword.trimmed
        guard !kw.isEmpty else { return .empty }
        if isDemo {
            return SearchResults(
                tracks: DemoData.tracks.filter { $0.title.localizedCaseInsensitiveContains(kw) },
                albums: DemoData.albums.filter { $0.name.localizedCaseInsensitiveContains(kw) },
                artists: DemoData.artists.filter { $0.name.localizedCaseInsensitiveContains(kw) }
            )
        }
        guard let creds = credentialsProvider?(), creds.isValid else { return .empty }
        do {
            let result = try await FeiNiuClient(credentials: creds).search(keyword: kw)
            return SearchResults(
                tracks: result.tracks.filter(\.isPlayable),
                albums: result.albums,
                artists: result.artists
            )
        } catch {
            // 防抖输入时旧的搜索会被取消，这是正常行为，不是错误
            if Self.isCancelled(error) {
                return .empty
            }
            Log.error("[Library] 搜索失败：\(error.localizedDescription)")
            return .empty
        }
    }

    /// 判断是否为任务取消（URLError.cancelled 或包装后的 FeiNiuError.cancelled）
    private static func isCancelled(_ error: Error) -> Bool {
        if let urlError = error as? URLError { return urlError.code == .cancelled }
        if let feiError = error as? FeiNiuError, let underlying = feiError.underlyingError as? URLError {
            return underlying.code == .cancelled
        }
        return false
    }

    // MARK: - 收藏

    func toggleFavorite(_ track: Track) async {
        if isDemo {
            if let idx = favorites.firstIndex(of: track) {
                favorites.remove(at: idx)
            } else {
                favorites.insert(track, at: 0)
            }
            return
        }
        guard let creds = credentialsProvider?(), creds.isValid else { return }
        let willBeFavorite = !favorites.contains(track)
        do {
            try await FeiNiuClient(credentials: creds).setFavorite(guid: track.guid, favorite: willBeFavorite)
            if willBeFavorite {
                if !favorites.contains(track) { favorites.insert(track, at: 0) }
            } else {
                favorites.removeAll { $0.guid == track.guid }
            }
            if let i = songs.firstIndex(of: track) { songs[i].isFavorite = willBeFavorite }
        } catch {
            Log.error("[Library] 收藏操作失败：\(error.localizedDescription)")
        }
    }

    func isFavorite(_ track: Track) -> Bool {
        favorites.contains(track) || track.isFavorite
    }

    func reset() {
        songs = []
        albums = []
        artists = []
        playlists = []
        genres = []
        favorites = []
        lastLoadedAt = nil
        errorMessage = nil
    }
}
