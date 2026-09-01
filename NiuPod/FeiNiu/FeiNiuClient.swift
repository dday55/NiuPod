import CryptoKit
import Foundation

/// 飞牛音乐服务 API 客户端
///
/// 所有请求自动携带 `Cookie: music-token=<token>`；中继链路额外携带
/// `mode=relay`。3xx 重定向手动跟随之保留 Cookie（系统自动跟随会丢自定义头，
/// 导致 `music-token` 不被携带）。
struct FeiNiuClient: Sendable {
    static let apiPrefix = "/music/api/v1"

    var credentials: Credentials
    var session: URLSession = .niupod

    // MARK: - 构造 / 地址

    init(credentials: Credentials) {
        self.credentials = credentials
    }

    func apiURL(_ path: String) -> URL? {
        let p = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: credentials.baseUrl + Self.apiPrefix + p)
    }

    /// 音频流地址：`/music/api/v1/track/stream?guid=`
    func streamURL(guid: String) -> URL? {
        apiURL("/track/stream?guid=\(guid)")
    }

    /// 封面地址：`/music/api/v1/static/cover?coverId=&size=`
    ///
    /// 全 App 统一请求 800px：URL 一致才能共享磁盘缓存，避免「列表已显示、
    /// 播放页还在转圈」。缩略场景靠解码尺寸省内存，不改 URL。
    func coverURL(coverId: String, size: Int = 800, updatedAt: Int? = nil) -> URL? {
        var p = "/static/cover?coverId=\(coverId)&size=\(size)"
        if let t = updatedAt, t > 0 { p += "&t=\(t)" }
        return apiURL(p)
    }

    /// 资源请求头（封面 / 音频流等，供 URLSession 与 AVAsset 使用）
    var resourceHeaders: [String: String] {
        var h: [String: String] = [:]
        let token = credentials.token
        if !token.isEmpty {
            h["Cookie"] = credentials.relayMode ? "mode=relay; music-token=\(token)" : "music-token=\(token)"
        }
        if let code = credentials.accessCode, !code.isEmpty {
            h["x-access-code"] = Data(code.utf8).base64EncodedString()
            h["x-access-source"] = "app"
        }
        return h
    }

    private var authHeaders: [String: String] {
        var h: [String: String] = [:]
        let token = credentials.token
        if !token.isEmpty {
            h["Cookie"] = credentials.relayMode ? "music-token=\(token); mode=relay" : "music-token=\(token)"
        }
        if let code = credentials.accessCode, !code.isEmpty {
            h["x-access-code"] = Data(code.utf8).base64EncodedString()
            h["x-access-source"] = "app"
        }
        return h
    }

    // MARK: - 底层请求

    /// 发起请求，手动跟随最多 5 跳 3xx（每跳都重新带上 Cookie）。
    /// 网络超时 / 断连时自动切换到另一条候选链路后重试一次。
    private func request(
        _ method: String,
        path: String,
        query: [String: String]? = nil,
        body: [String: Any]? = nil,
        extraHeaders: [String: String] = [:],
        allowFailover: Bool = true
    ) async throws -> HTTPResult {
        guard var url = apiURL(path) else { throw FeiNiuError.invalidURL(path) }
        if let query, !query.isEmpty {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            if let u = comps?.url { url = u }
        }

        var headers = authHeaders
        headers.merge(extraHeaders) { _, new in new }

        var httpBody: Data?
        if let body {
            httpBody = try? JSONSerialization.data(withJSONObject: body)
            headers["Content-Type"] = "application/json"
        }

        do {
            return try await perform(method: method, url: url, headers: headers, body: httpBody, depth: 0)
        } catch {
            // 网络超时/断连 → 自动切换链路后重试（只切一次，避免级联）
            if allowFailover, Self.isFailoverableNetworkError(error),
               let newCreds = await FailoverCoordinator.shared.switchCredentials(current: credentials) {
                var client = FeiNiuClient(credentials: newCreds)
                client.session = session
                return try await client.request(
                    method, path: path, query: query, body: body,
                    extraHeaders: extraHeaders, allowFailover: false
                )
            }
            throw error
        }
    }

    /// 是否值得触发链路自动切换的网络错误（超时 / 连不上 / DNS / 断网 / 证书…）
    static func isFailoverableNetworkError(_ error: Error) -> Bool {
        let underlying = (error as? FeiNiuError)?.underlyingError ?? error
        guard let urlError = underlying as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet, .secureConnectionFailed,
             .serverCertificateUntrusted, .cannotLoadFromNetwork, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    private func perform(
        method: String,
        url: URL,
        headers: [String: String],
        body: Data?,
        depth: Int
    ) async throws -> HTTPResult {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.allHTTPHeaderFields = headers
        req.httpBody = body
        // 10s：太短在弱网/中继下容易误判，太长会拖慢「链路不可用 → 自动切换」
        req.timeoutInterval = 10

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw FeiNiuError.network(underlying: URLError(.badServerResponse))
        }
        let hdrs = http.allHeaderFields.reduce(into: [String: String]()) { acc, pair in
            if let k = pair.key as? String, let v = pair.value as? String { acc[k.lowercased()] = v }
        }
        let status = http.statusCode

        if status >= 300, status < 400, depth < 5,
           let location = hdrs["location"], !location.isEmpty,
           let next = URL(string: location, relativeTo: url) {
            // 防自循环：nginx「HTTP 强制跳转 HTTPS」规则误命中 HTTPS 端口时会 302 回自己
            guard next.absoluteString != url.absoluteString else {
                return HTTPResult(status: status, headers: hdrs, data: data, finalURL: url)
            }
            Log.net("[Api] 3xx → \(next.absoluteString) (depth=\(depth))")
            return try await perform(method: method, url: next, headers: headers, body: body, depth: depth + 1)
        }

        return HTTPResult(status: status, headers: hdrs, data: data, finalURL: url)
    }

    /// 解出业务 `data`；非 0 业务码统一抛错，401 与 INVALID TOKEN 映射为会话失效
    private func unwrap(_ result: HTTPResult) throws -> [String: Any] {
        let json = result.json ?? [:]
        if result.status == 401 { throw FeiNiuError.unauthorized }
        if let code = AnyCodable.int(json["code"]) {
            if code == 401 { throw FeiNiuError.unauthorized }
            if code != 0 {
                let msg = AnyCodable.string(json["msg"]) ?? ""
                if msg.lowercased().contains("invalid token") { throw FeiNiuError.unauthorized }
                throw FeiNiuError.server(code: code, msg: msg.isEmpty ? "请求失败（\(code)）" : msg)
            }
        } else if result.status >= 400 {
            throw FeiNiuError.httpStatus(result.status, nil)
        }
        return (json["data"] as? [String: Any]) ?? json
    }

    private func unwrapPage<T>(_ result: HTTPResult, map: ([String: Any]) -> T) throws -> PageData<T> {
        let data = try unwrap(result)
        guard let json = result.json, let dataObj = json["data"] as? [String: Any] else {
            // 部分接口直接把分页字段平铺在 data 上
            return PageData(json: data, map: map)
        }
        return PageData(json: dataObj, map: map)
    }

    // MARK: - 1. 登录

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// 生成 32 位 hex 设备 ID
    static func generateDeviceId() -> String {
        (0..<16).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined()
    }

    /// 密码登录。密码以 SHA256 摘要传输（与飞牛各端一致）。
    func login(
        username: String,
        password: String,
        deviceId: String
    ) async throws -> LoginResult {
        let body: [String: Any] = [
            "username": username,
            "password": Self.sha256(password),
            "deviceId": deviceId,
        ]
        // 登录请求自身没有有效 token，中继模式下只带 mode=relay
        let extra: [String: String] = credentials.relayMode ? ["Cookie": "mode=relay"] : [:]
        let result = try await request("POST", path: "/user/password-login", body: body, extraHeaders: extra)

        // 走到这里仍是 3xx → 重定向没被正常消化（典型：HTTPS 端口被 HTTP 跳转规则误拦截）
        if result.status >= 300, result.status < 400 {
            throw FeiNiuError.server(
                code: result.status,
                msg: "服务器返回重定向 (HTTP \(result.status))，请检查「HTTP 强制跳转 HTTPS」配置是否误拦截了 HTTPS 请求"
            )
        }

        let json = result.json ?? [:]
        let code = AnyCodable.int(json["code"]) ?? -1
        guard code == 0, let dataObj = json["data"] as? [String: Any] else {
            // 120001：账号或密码错误（服务端 msg 为英文，换成中文提示）
            if code == 120001 { throw FeiNiuError.server(code: code, msg: "用户名或密码错误") }
            let msg = AnyCodable.string(json["msg"]) ?? "登录失败"
            throw FeiNiuError.server(code: code, msg: msg)
        }
        return LoginResult(json: dataObj)
    }

    // MARK: - 2. 歌曲

    func tracks(page: Int = 1, size: Int = 100, sort: String? = nil) async throws -> PageData<Track> {
        var q = ["page": "\(page)", "size": "\(size)"]
        if let sort { q["sort"] = sort }
        let r = try await request("GET", path: "/track/list", query: q)
        return try unwrapPage(r) { Track(json: $0) }
    }

    func track(guid: String) async throws -> Track? {
        let r = try await request("GET", path: "/track/metadata", query: ["guid": guid])
        let data = try unwrap(r)
        if let t = data["track"] as? [String: Any] { return Track(json: t) }
        return Track(json: data)
    }

    // MARK: - 3. 专辑

    func albums(page: Int = 1, size: Int = 100) async throws -> PageData<Album> {
        let r = try await request("GET", path: "/album/list", query: ["page": "\(page)", "size": "\(size)"])
        return try unwrapPage(r) { Album(json: $0) }
    }

    func albumTracks(guid: String, page: Int = 1, size: Int = 200) async throws -> PageData<Track> {
        // 官方接口：/track/album-detail/list，参数是 albumGUID（全大写）
        let r = try await request("GET", path: "/track/album-detail/list",
                                  query: ["guid": guid, "albumGUID": guid,
                                          "page": "\(page)", "size": "\(size)"])
        return try unwrapPage(r) { Track(json: $0) }
    }

    // MARK: - 4. 歌手

    func artists(page: Int = 1, size: Int = 100) async throws -> PageData<Artist> {
        let r = try await request("GET", path: "/artist/list", query: ["page": "\(page)", "size": "\(size)"])
        return try unwrapPage(r) { Artist(json: $0) }
    }

    func artistTracks(guid: String, page: Int = 1, size: Int = 200) async throws -> PageData<Track> {
        // 官方接口：/track/artist-detail/list，参数是 artistGUID（全大写）
        let r = try await request("GET", path: "/track/artist-detail/list",
                                  query: ["guid": guid, "artistGUID": guid,
                                          "page": "\(page)", "size": "\(size)"])
        return try unwrapPage(r) { Track(json: $0) }
    }

    // MARK: - 5. 风格

    func genres(page: Int = 1, size: Int = 100) async throws -> PageData<Genre> {
        let r = try await request("GET", path: "/genre/list", query: ["page": "\(page)", "size": "\(size)"])
        return try unwrapPage(r) { Genre(json: $0) }
    }

    func genreTracks(guid: String, page: Int = 1, size: Int = 200) async throws -> PageData<Track> {
        // 官方接口：/track/genre-detail/list，参数是 genreGUID（全大写）
        let r = try await request("GET", path: "/track/genre-detail/list",
                                  query: ["guid": guid, "genreGUID": guid,
                                          "page": "\(page)", "size": "\(size)"])
        return try unwrapPage(r) { Track(json: $0) }
    }

    // MARK: - 6. 歌单

    func playlists(page: Int = 1, size: Int = 100) async throws -> PageData<Playlist> {
        let r = try await request("GET", path: "/playlist/list", query: ["page": "\(page)", "size": "\(size)"])
        return try unwrapPage(r) { Playlist(json: $0) }
    }

    func playlistTracks(guid: String, page: Int = 1, size: Int = 500) async throws -> PageData<Track> {
        // 官方接口：/track/playlist-detail/list，参数是 playlistGUID（全大写）
        let r = try await request("GET", path: "/track/playlist-detail/list",
                                  query: ["guid": guid, "playlistGUID": guid,
                                          "page": "\(page)", "size": "\(size)"])
        return try unwrapPage(r) { Track(json: $0) }
    }

    // MARK: - 7. 收藏

    func favorites(page: Int = 1, size: Int = 200) async throws -> PageData<Track> {
        let r = try await request("GET", path: "/favorite-track/list", query: ["page": "\(page)", "size": "\(size)"])
        return try unwrapPage(r) { Track(json: $0) }
    }

    func setFavorite(guid: String, favorite: Bool) async throws {
        let path = favorite ? "/favorite-track/add" : "/favorite-track/remove"
        _ = try await request("POST", path: path, body: ["guid": guid])
    }

    // MARK: - 8. 歌词

    func lyrics(trackGUID: String) async throws -> LyricResponse {
        let r = try await request("GET", path: "/lyric/list", query: ["trackGUID": trackGUID])
        let data = try unwrap(r)
        return LyricResponse(json: data)
    }

    func lyricText(trackGUID: String) async throws -> String? {
        try await lyrics(trackGUID: trackGUID).preferredContent
    }

    // MARK: - 9. 搜索

    func search(keyword: String, size: Int = 30) async throws -> SearchResults {
        // 官方接口的关键词参数名是 `q`（参考第三方实现与签名测试），
        // 传 `keyword` 会被服务端忽略，返回空结果。
        let q = ["q": keyword, "page": "1", "size": "\(size)"]
        async let tr = request("GET", path: "/search/track", query: q)
        async let al = request("GET", path: "/search/album", query: q)
        async let ar = request("GET", path: "/search/artist", query: q)
        let (r1, r2, r3) = try await (tr, al, ar)
        return SearchResults(
            tracks: (try? parseSearchPage(r1) { Track(json: $0) }.list) ?? [],
            albums: (try? parseSearchPage(r2) { Album(json: $0) }.list) ?? [],
            artists: (try? parseSearchPage(r3) { Artist(json: $0) }.list) ?? []
        )
    }

    /// 解析搜索分页：官方搜索接口的 `data` 可能是裸数组，也可能是
    /// `{list|tracks|albums|artists|items, ...}` 对象，全部兼容。
    func parseSearchPage<T>(_ result: HTTPResult, map: ([String: Any]) -> T) throws -> PageData<T> {
        let json = result.json ?? [:]
        if let arr = json["data"] as? [Any] {
            return PageData(list: arr.compactMap { $0 as? [String: Any] }.map(map), total: arr.count)
        }
        if let dataObj = json["data"] as? [String: Any] {
            for key in ["list", "items", "tracks", "albums", "artists", "songs"] {
                if let arr = dataObj[key] as? [Any] {
                    return PageData(list: arr.compactMap { $0 as? [String: Any] }.map(map), total: arr.count)
                }
            }
        }
        return try unwrapPage(result, map: map)
    }

    // MARK: - 10. 播放历史 / 上报

    func playHistory(page: Int = 1, size: Int = 100) async throws -> PageData<Track> {
        let r = try await request("GET", path: "/history/list", query: ["page": "\(page)", "size": "\(size)"])
        return try unwrapPage(r) { Track(json: $0) }
    }

    func reportPlay(trackGuid: String) async {
        _ = try? await request("POST", path: "/track/play", body: ["guid": trackGuid])
    }

    // MARK: - 11. 安全码

    /// 探测服务器是否要求安全码：204 不需要，401 需要
    func requiresAccessCode() async -> Bool {
        guard let url = URL(string: credentials.baseUrl + "/access_code_verify") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        if credentials.relayMode { req.setValue("mode=relay", forHTTPHeaderField: "Cookie") }
        guard let (_, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 401
    }

    /// 校验安全码
    func verifyAccessCode(_ code: String) async -> Bool {
        guard let url = URL(string: credentials.baseUrl + "/access_code_verify") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        if credentials.relayMode { req.setValue("mode=relay", forHTTPHeaderField: "Cookie") }
        req.setValue(Data(code.utf8).base64EncodedString(), forHTTPHeaderField: "x-access-code")
        req.setValue("app", forHTTPHeaderField: "x-access-source")
        guard let (_, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    // MARK: - 11. 全量拉取（翻页）

    /// 逐页拉取，直到拿完全部数据
    ///
    /// 服务端对 `size` 有上限（实测约 50：传 5000 也只返回 50 条），所以**只拉第一页
    /// 会漏掉绝大部分曲目**——之前就是这么写的，表现是「曲库只有 50 首」。
    ///
    /// 结束条件：优先用服务端返回的 `total`；`total` 缺失时一直翻到拿到空页为止，
    /// 因为「返回条数少于请求数」很可能只是被截断，并不是最后一页。
    func fetchAllPages<T>(
        requestedSize: Int,
        maxPages: Int = 400,
        fetch: (Int, Int) async throws -> PageData<T>
    ) async throws -> [T] {
        var result: [T] = []
        var page = 1
        var pageSize = requestedSize
        var total: Int?

        while page <= maxPages {
            let pageData = try await fetch(page, pageSize)
            result.append(contentsOf: pageData.list)
            if pageData.list.isEmpty { break }

            if page == 1 {
                // 用实际返回量当后续页大小：服务端若截断了 size，之后也按这个量请求，
                // 既不跳号也不重复
                pageSize = pageData.list.count
                if pageData.total > 0 { total = pageData.total }
            }
            if let total, result.count >= total { break }
            page += 1
        }
        return result
    }

    func allTracks(sort: String? = nil) async throws -> [Track] {
        try await fetchAllPages(requestedSize: 500) { page, size in
            try await tracks(page: page, size: size, sort: sort)
        }
    }

    func allAlbums() async throws -> [Album] {
        try await fetchAllPages(requestedSize: 500) { page, size in
            try await albums(page: page, size: size)
        }
    }

    func allArtists() async throws -> [Artist] {
        try await fetchAllPages(requestedSize: 500) { page, size in
            try await artists(page: page, size: size)
        }
    }

    func allPlaylists() async throws -> [Playlist] {
        try await fetchAllPages(requestedSize: 200) { page, size in
            try await playlists(page: page, size: size)
        }
    }

    func allGenres() async throws -> [Genre] {
        try await fetchAllPages(requestedSize: 200) { page, size in
            try await genres(page: page, size: size)
        }
    }

    func allFavorites() async throws -> [Track] {
        try await fetchAllPages(requestedSize: 500) { page, size in
            try await favorites(page: page, size: size)
        }
    }

    /// 专辑内曲目（同样会被截断，需要翻页）
    func allAlbumTracks(guid: String) async throws -> [Track] {
        try await fetchAllPages(requestedSize: 500) { page, size in
            try await albumTracks(guid: guid, page: page, size: size)
        }
    }

    func allArtistTracks(guid: String) async throws -> [Track] {
        try await fetchAllPages(requestedSize: 500) { page, size in
            try await artistTracks(guid: guid, page: page, size: size)
        }
    }

    func allPlaylistTracks(guid: String) async throws -> [Track] {
        try await fetchAllPages(requestedSize: 500) { page, size in
            try await playlistTracks(guid: guid, page: page, size: size)
        }
    }

    func allGenreTracks(guid: String) async throws -> [Track] {
        try await fetchAllPages(requestedSize: 500) { page, size in
            try await genreTracks(guid: guid, page: page, size: size)
        }
    }

    // MARK: - 12. 连通性快检

    /// 用当前凭据打一次轻量接口，验证链路+token 仍然有效。
    /// 用独立短超时（5s）：当前链路不通时快速失败，避免重连/自动切换前
    /// 干等 10-20 秒才确认「不可用」。
    func ping() async -> Bool {
        guard let url = apiURL("/track/list?page=1&size=1") else { return false }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        req.allHTTPHeaderFields = authHeaders
        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode == 200
        } catch {
            return false
        }
    }
}
