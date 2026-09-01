import XCTest
@testable import NiuPod

/// 核心逻辑单测：MD5 / 候选构建 / LRC / 探测判定
final class CoreTests: XCTestCase {

    // MARK: - MD5（authx 签名的基础，必须与标准完全一致）

    func testMD5Vectors() {
        XCTAssertEqual(MD5.hex(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(MD5.hex("a"), "0cc175b9c0f1b6a831c399e269772661")
        XCTAssertEqual(MD5.hex("abc"), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(MD5.hex("message digest"), "f96b697d7cb7938d525a2f31aaf161d0")
        XCTAssertEqual(MD5.hex("abcdefghijklmnopqrstuvwxyz"), "c3fcd3d76192e4007dfb496cca67e13b")

    }
    func testMD5LongInputAcrossBlockBoundary() {
        // 56 字节是补位临界点（56+8=64 恰好一个块），64/80 字节验证跨块与长度编码
        let s56 = String(repeating: "a", count: 56)
        let s64 = String(repeating: "a", count: 64)
        let s80 = String(repeating: "1234567890", count: 8)
        XCTAssertEqual(MD5.hex(s56), "3b0c8ac703f828b04c6c197006d17218")
        XCTAssertEqual(MD5.hex(s64), "014842d480b571495a4a0363793f7367")
        XCTAssertEqual(MD5.hex(s80), "57edf4a22be3c955ac49da2e2107b67a")
        XCTAssertNotEqual(MD5.hex(s56), MD5.hex(s64))
    }

    func testMD5MultibyteUTF8() {
        // 非 ASCII 必须按 UTF-8 字节计算
        XCTAssertEqual(MD5.hex("中文"), "a7bac2239fcdcb3a067903d8077c4a07")
    }

    // MARK: - authx 签名

    func testAuthxFormat() {
        let authx = FnConnectAPI.authx(method: "post", url: "/api/v1/fn/con", bodyJSON: #"{"fnId":"abc"}"#)
        let parts = authx.components(separatedBy: "&")
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts[0].hasPrefix("nonce="))
        XCTAssertTrue(parts[1].hasPrefix("timestamp="))
        XCTAssertTrue(parts[2].hasPrefix("sign="))
        // nonce 6 位数字
        let nonce = parts[0].replacingOccurrences(of: "nonce=", with: "")
        XCTAssertEqual(nonce.count, 6)
        XCTAssertNotNil(Int(nonce))
        // sign 32 位 hex
        let sign = parts[2].replacingOccurrences(of: "sign=", with: "")
        XCTAssertEqual(sign.count, 32)
    }

    func testDartJSONMatchesDartJsonEncode() {
        // 飞牛 authx 只签名单键 JSON（{"fnId":"xxx"}），单键场景下与 Dart jsonEncode 一致
        XCTAssertEqual(DartJSON.encode(["fnId": "abc123"]), #"{"fnId":"abc123"}"#)
        // 斜杠不被转义、非 ASCII 原样输出（与 Dart jsonEncode 一致；Foundation 会多加反斜杠）
        XCTAssertEqual(DartJSON.encode(["u": "a/b"]), #"{"u":"a/b"}"#)
        XCTAssertEqual(DartJSON.encode(["u": "中文"]), #"{"u":"中文"}"#)
        XCTAssertEqual(DartJSON.encode(["u": "a\"b\\c\nd"]), #"{"u":"a\"b\\c\nd"}"#)
        XCTAssertEqual(DartJSON.encode(["n": 1]), #"{"n":1}"#)
        // 多键 Swift Dictionary 不保证顺序，不能断言具体顺序；这里只验证合法性
        let multi = DartJSON.encode(["n": 1, "b": true])
        XCTAssertTrue(multi.contains(#""n":1"#) && multi.contains(#""b":true"#))
    }

    // MARK: - 候选链路构建

    func testCandidateOrderAndSchemes() {
        var params = FnConnectionParams()
        params.internalIPv4s = ["192.168.11.200"]
        params.publicIPv4s = ["120.239.1.2"]
        params.publicIPv6s = ["2409:8a00::1"]
        params.relayAddresses = ["abc.5ddd.com:443"]
        params.httpPort = 5666
        params.httpsPort = 5667

        let specs = ProbeCandidateBuilder.build(
            fnId: "abc", params: params, order: kDefaultConnectionOrder
        )

        // 内网 2 + v6 2 + v4 2 + 中继 1 = 7
        XCTAssertEqual(specs.count, 7)
        XCTAssertEqual(specs[0].address, "http://192.168.11.200:5666")
        XCTAssertEqual(specs[1].address, "https://192.168.11.200:5667")
        XCTAssertEqual(specs[2].address, "http://[2409:8a00::1]:5666")
        XCTAssertEqual(specs[4].address, "http://120.239.1.2:5666")
        XCTAssertEqual(specs[6].address, "https://abc.5ddd.com")
        XCTAssertTrue(specs[6].relayMode)
        XCTAssertFalse(specs[0].relayMode)
        XCTAssertEqual(specs[0].group, ProbeCandidateGroup.internal)
        XCTAssertEqual(specs[6].group, ProbeCandidateGroup.relay)
    }

    func testRelayFallbackAddress() {
        var params = FnConnectionParams()
        params.relayAddresses = []
        let specs = ProbeCandidateBuilder.build(
            fnId: "myhost", params: params, order: [.relay]
        )
        XCTAssertEqual(specs.count, 1)
        XCTAssertEqual(specs[0].address, "https://myhost.5ddd.com")
        // 已经是完整域名时不重复拼后缀
        let specs2 = ProbeCandidateBuilder.build(
            fnId: "myhost.5ddd.com", params: params, order: [.relay]
        )
        XCTAssertEqual(specs2[0].address, "https://myhost.5ddd.com")
    }

    func testEmptyGroupsContributeNothing() {
        let specs = ProbeCandidateBuilder.build(
            fnId: "x", params: FnConnectionParams(), order: kDefaultConnectionOrder
        )
        XCTAssertEqual(specs.count, 1)      // 只有中继兜底
        XCTAssertEqual(specs[0].group, ProbeCandidateGroup.relay)
    }

    // MARK: - 探测判定

    func testProbeVerdict() {
        // 未鉴权：拿到响应即可用（含 401，说明链路通）
        XCTAssertTrue(ProbeVerdict.isUsable(status: 401, location: nil, body: nil, authChecked: false).usable)
        // 已鉴权：401 不可用
        XCTAssertFalse(ProbeVerdict.isUsable(status: 401, location: nil, body: nil, authChecked: true).usable)
        // 已鉴权：业务码非 0 不可用
        XCTAssertFalse(ProbeVerdict.isUsable(status: 200, location: nil, body: ["code": 401], authChecked: true).usable)
        XCTAssertTrue(ProbeVerdict.isUsable(status: 200, location: nil, body: ["code": 0], authChecked: true).usable)
        // INVALID TOKEN（HTTP 200 承载）
        XCTAssertFalse(ProbeVerdict.isUsable(status: 200, location: nil, body: ["msg": "INVALID TOKEN"], authChecked: true).usable)
        // HTTP 302 → HTTPS：无论是否鉴权都不可用
        let r = ProbeVerdict.isUsable(status: 302, location: "https://host:5667/music/api/v1/track/list", body: nil, authChecked: false)
        XCTAssertFalse(r.usable)
        XCTAssertTrue(r.reason?.contains("HTTPS") == true)
        // 相对路径重定向不算强制跳转
        XCTAssertTrue(ProbeVerdict.isUsable(status: 302, location: "/login", body: nil, authChecked: false).usable)
    }

    func testProbeTimeout() {
        XCTAssertEqual(ProbeVerdict.timeout(isRelay: true), 10)
        XCTAssertEqual(ProbeVerdict.timeout(isRelay: false), 3)
    }

    // MARK: - LRC

    func testLRCBasic() {
        let lrc = """
        [ti:晴天]
        [ar:周杰伦]
        [al:叶惠美]
        [00:00.00]晴天 - 周杰伦
        [00:12.50]故事的小黄花
        [00:18.20]从出生那年就飘着
        """
        let r = LRCParser.parse(lrc)
        XCTAssertEqual(r.title, "晴天")
        XCTAssertEqual(r.artist, "周杰伦")
        XCTAssertEqual(r.album, "叶惠美")
        XCTAssertEqual(r.lines.count, 3)
        XCTAssertEqual(r.lines[1].text, "故事的小黄花")
        XCTAssertEqual(r.lines[1].time, 12.5, accuracy: 0.001)
    }

    func testLRCTranslationMerge() {
        // 同一时间戳两次出现 → 第二条作为译文
        let lrc = """
        [00:10.00]Hello
        [00:10.00]你好
        [00:15.00]World
        """
        let r = LRCParser.parse(lrc)
        XCTAssertEqual(r.lines.count, 2)
        XCTAssertEqual(r.lines[0].text, "Hello")
        XCTAssertEqual(r.lines[0].translation, "你好")
    }

    func testLRCOffset() {
        let lrc = "[offset:-500]\n[00:10.00]a\n"
        let r = LRCParser.parse(lrc)
        XCTAssertEqual(r.offsetMs, -500)
        // offset -500ms → 时间轴右移 0.5s
        XCTAssertEqual(r.lines[0].time, 10.5, accuracy: 0.001)
    }

    func testLRCWordTiming() {
        let lrc = "[00:10.00]<00:10.00>故<00:10.30>事<00:10.60>里\n"
        let r = LRCParser.parse(lrc)
        XCTAssertEqual(r.lines.count, 1)
        XCTAssertEqual(r.lines[0].text, "故事里")
        XCTAssertEqual(r.lines[0].words.count, 3)
        XCTAssertEqual(r.lines[0].words[1].text, "事")
        XCTAssertEqual(r.lines[0].words[1].time, 10.3, accuracy: 0.001)
    }

    func testLRCIndexLookup() {
        let lrc = "[00:05.00]a\n[00:10.00]b\n[00:20.00]c\n"
        let lines = LRCParser.parse(lrc).lines
        XCTAssertEqual(LRCParser.index(of: 0, in: lines), -1)
        XCTAssertEqual(LRCParser.index(of: 5, in: lines), 0)
        XCTAssertEqual(LRCParser.index(of: 12, in: lines), 1)
        XCTAssertEqual(LRCParser.index(of: 99, in: lines), 2)
    }

    // MARK: - 地址归一化

    func testNormalizeBaseUrl() {
        XCTAssertEqual(Credentials.normalizeBaseUrl("http://1.2.3.4:5666"), "http://1.2.3.4:5666")
        XCTAssertEqual(Credentials.normalizeBaseUrl("http://1.2.3.4:5666/"), "http://1.2.3.4:5666")
        XCTAssertEqual(Credentials.normalizeBaseUrl("http://1.2.3.4:5666/music/api/v1"), "http://1.2.3.4:5666")
        XCTAssertEqual(Credentials.normalizeBaseUrl("  https://host  "), "https://host")
    }

    // MARK: - 宽容类型解析

    func testAnyCodableTolerantParsing() {
        XCTAssertEqual(AnyCodable.int("1714521600"), 1714521600)
        XCTAssertEqual(AnyCodable.int(42), 42)
        XCTAssertEqual(AnyCodable.int(NSNumber(value: 7)), 7)
        XCTAssertNil(AnyCodable.int("abc"))
        XCTAssertNil(AnyCodable.int("  "))
        XCTAssertEqual(AnyCodable.bool("1"), true)
        XCTAssertEqual(AnyCodable.bool("0"), false)
        XCTAssertEqual(AnyCodable.bool(1), true)
        XCTAssertNil(AnyCodable.bool("maybe"))
    }

    func testTrackParsesAccessStatus3AsDeleted() {
        let json: [String: Any] = [
            "guid": "g1", "title": "t", "accessStatus": 3,
            "createdAt": 0, "updatedAt": 0, "album": [:], "artists": [],
        ]
        XCTAssertTrue(Track(json: json).isAudioFileDeleted)
        let ok: [String: Any] = [
            "guid": "g2", "title": "t", "accessStatus": 0,
            "createdAt": 0, "updatedAt": 0, "album": [:], "artists": [],
        ]
        XCTAssertFalse(Track(json: ok).isAudioFileDeleted)
    }

    // MARK: - SHA256（登录密码摘要）

    func testSHA256() {
        XCTAssertEqual(
            FeiNiuClient.sha256("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(FeiNiuClient.generateDeviceId().count, 32)
    }
    // MARK: - 可播放性过滤（不支持的格式直接跳过）

    private func makeTrack(format: String? = nil, codec: String? = nil, deleted: Bool = false) -> Track {
        var spec: [String: Any] = [:]
        if let format { spec["format"] = format }
        if let codec { spec["codec"] = codec }
        var json: [String: Any] = [
            "guid": UUID().uuidString,
            "title": "测试曲目",
            "album": [String: Any](),
            "artists": [],
            "genres": [],
            "audioSpec": spec,
        ]
        if deleted { json["accessStatus"] = 3 }
        return Track(json: json)
    }

    func testUnsupportedFormatsAreFlagged() {
        XCTAssertTrue(makeTrack(format: "APE").isFormatUnsupported)
        XCTAssertTrue(makeTrack(format: "WMA").isFormatUnsupported)
        XCTAssertTrue(makeTrack(format: "ogg").isFormatUnsupported)
        XCTAssertTrue(makeTrack(format: "opus").isFormatUnsupported)
        XCTAssertTrue(makeTrack(format: "dsf").isFormatUnsupported)
        XCTAssertTrue(makeTrack(format: "dff").isFormatUnsupported)
        XCTAssertTrue(makeTrack(format: "wma lossless").isFormatUnsupported)
        XCTAssertTrue(makeTrack(codec: "ape").isFormatUnsupported)
    }

    func testSupportedFormatsAreKept() {
        XCTAssertFalse(makeTrack(format: "mp3").isFormatUnsupported)
        XCTAssertFalse(makeTrack(format: "FLAC").isFormatUnsupported)
        XCTAssertFalse(makeTrack(format: "m4a").isFormatUnsupported)
        XCTAssertFalse(makeTrack(format: "aac").isFormatUnsupported)
        XCTAssertFalse(makeTrack(format: "wav").isFormatUnsupported)
        XCTAssertFalse(makeTrack(format: "alac").isFormatUnsupported)
        XCTAssertFalse(makeTrack(format: "Apple Lossless").isFormatUnsupported)
        XCTAssertFalse(makeTrack(format: "MPEG-4 Audio").isFormatUnsupported)
    }

    func testUnknownFormatIsKept() {
        XCTAssertFalse(makeTrack().isFormatUnsupported)
        XCTAssertFalse(makeTrack(format: "").isFormatUnsupported)
    }

    func testPlayableAccountsForDeletedFile() {
        XCTAssertTrue(makeTrack(format: "mp3").isPlayable)
        XCTAssertFalse(makeTrack(format: "mp3", deleted: true).isPlayable)
        XCTAssertFalse(makeTrack(format: "ape").isPlayable)
    }
}

// MARK: - 全量分页拉取

/// 服务端会把 size 截断到上限（实测约 50），只拉第一页会漏掉绝大部分数据。
/// 这组测试用假的分页闭包模拟该行为，验证翻页能拿全。
final class PaginationTests: XCTestCase {

    private let client = FeiNiuClient(credentials: Credentials())

    /// 模拟「无论请求多少，每页最多 cap 条」的服务端
    private func cappedFetch(total: Int, cap: Int, reportTotal: Bool)
        -> (Int, Int) async throws -> PageData<String> {
        { page, _ in
            let start = (page - 1) * cap
            let count = max(0, min(cap, total - start))
            return PageData(list: (0..<count).map { "item\(start + $0)" },
                            total: reportTotal ? total : 0)
        }
    }

    func testFetchesAllPagesWhenServerCapsSize() async throws {
        let result = try await client.fetchAllPages(requestedSize: 500,
                                                    fetch: cappedFetch(total: 137, cap: 50, reportTotal: true))
        XCTAssertEqual(result.count, 137)
        XCTAssertEqual(result.first, "item0")
        XCTAssertEqual(result.last, "item136")
    }

    func testFetchesAllPagesWithoutTotal() async throws {
        // total 缺失时靠空页停止，同样要拿全
        let result = try await client.fetchAllPages(requestedSize: 500,
                                                    fetch: cappedFetch(total: 120, cap: 50, reportTotal: false))
        XCTAssertEqual(result.count, 120)
        XCTAssertEqual(result.last, "item119")
    }

    func testSinglePageWhenDataFitsInCap() async throws {
        let result = try await client.fetchAllPages(requestedSize: 500,
                                                    fetch: cappedFetch(total: 23, cap: 50, reportTotal: true))
        XCTAssertEqual(result.count, 23)
    }

    func testEmptyLibrary() async throws {
        let result = try await client.fetchAllPages(requestedSize: 500,
                                                    fetch: cappedFetch(total: 0, cap: 50, reportTotal: true))
        XCTAssertTrue(result.isEmpty)
    }

    func testTerminatesEvenIfServerAlwaysReturnsFullPages() async throws {
        // 恶意/异常服务端永远返回满页且 total 说不清 → 靠 maxPages 兜底，不能死循环
        let result = try await client.fetchAllPages(
            requestedSize: 100,
            maxPages: 5,
            fetch: { page, size in
                PageData(list: (0..<size).map { "p\(page)-\($0)" }, total: 0)
            }
        )
        XCTAssertEqual(result.count, 500)   // 5 页 × 100
    }


    // MARK: - 音频流 URL / 资源加载器

    func testStreamURLIsRealHTTP() {
        let creds = Credentials(baseUrl: "http://192.168.11.200:5666", token: "t", relayMode: false,
                                accessCode: nil, fnId: "", username: "", deviceId: "")
        let url = FeiNiuClient(credentials: creds).streamURL(guid: "abc123")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, "http")
        XCTAssertEqual(url?.host, "192.168.11.200")
        XCTAssertTrue(url?.absoluteString.contains("guid=abc123") ?? false)
    }

    func testResourceLoaderPlaceholderURLHasValidHost() {
        // 自定义 scheme 必须带合法 host：空 host / `.local` 都可能被 AVFoundation
        // 直接判为「不支持的 URL」，连 resourceLoader 都不调用。
        let url = CookieAssetLoader.placeholderURL(for: "abc123")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, "niupod-stream")
        let host = url?.host ?? ""
        XCTAssertFalse(host.isEmpty)
        XCTAssertEqual(host, "127.0.0.1")
        XCTAssertTrue(url?.absoluteString.contains("abc123") ?? false)
        XCTAssertTrue(url?.absoluteString.hasSuffix(".mp3") ?? false)
    }

    // MARK: - 网络自动切换判定

    func testFailoverTriggersOnNetworkErrors() {
        XCTAssertTrue(FeiNiuClient.isFailoverableNetworkError(URLError(.timedOut)))
        XCTAssertTrue(FeiNiuClient.isFailoverableNetworkError(URLError(.cannotConnectToHost)))
        XCTAssertTrue(FeiNiuClient.isFailoverableNetworkError(URLError(.dnsLookupFailed)))
        XCTAssertTrue(FeiNiuClient.isFailoverableNetworkError(URLError(.notConnectedToInternet)))
        XCTAssertTrue(FeiNiuClient.isFailoverableNetworkError(URLError(.secureConnectionFailed)))
        // 包一层 FeiNiuError.network 也应识别
        XCTAssertTrue(FeiNiuClient.isFailoverableNetworkError(
            FeiNiuError.network(underlying: URLError(.timedOut))
        ))
    }

    func testFailoverDoesNotTriggerOnOtherErrors() {
        XCTAssertFalse(FeiNiuClient.isFailoverableNetworkError(URLError(.cancelled)))
        XCTAssertFalse(FeiNiuClient.isFailoverableNetworkError(FeiNiuError.unauthorized))
        XCTAssertFalse(FeiNiuClient.isFailoverableNetworkError(
            FeiNiuError.server(code: 500, msg: "boom")
        ))
        XCTAssertFalse(FeiNiuClient.isFailoverableNetworkError(
            FeiNiuError.httpStatus(404, nil)
        ))
    }

    // MARK: - 搜索解析

    func testSearchParsesRawArrayData() throws {
        // 官方搜索接口的 data 可能是裸数组，不能只认 {list,total}
        let json = #"{"code":0,"msg":"ok","data":[{"guid":"t1","title":"夜航西飞"},{"guid":"t2","title":"Moonlight"}]}"#
        let result = HTTPResult(status: 200, headers: [:],
                                data: Data(json.utf8),
                                finalURL: URL(string: "http://x")!)
        let client = FeiNiuClient(credentials: Credentials())
        let page = try client.parseSearchPage(result) { Track(json: $0) }
        XCTAssertEqual(page.list.count, 2)
        XCTAssertEqual(page.list.first?.guid, "t1")
    }

    func testSearchParsesPagedData() throws {
        let json = #"{"code":0,"msg":"ok","data":{"list":[{"guid":"t1","title":"夜航西飞"}],"total":1}}"#
        let result = HTTPResult(status: 200, headers: [:],
                                data: Data(json.utf8),
                                finalURL: URL(string: "http://x")!)
        let client = FeiNiuClient(credentials: Credentials())
        let page = try client.parseSearchPage(result) { Track(json: $0) }
        XCTAssertEqual(page.list.count, 1)
        XCTAssertEqual(page.list.first?.title, "夜航西飞")
    }

    func testSearchParsesTracksKey() throws {
        // 部分版本返回 data.tracks 而不是 data.list
        let json = #"{"code":0,"msg":"ok","data":{"tracks":[{"guid":"t1","title":"夜航西飞"}],"total":1}}"#
        let result = HTTPResult(status: 200, headers: [:],
                                data: Data(json.utf8),
                                finalURL: URL(string: "http://x")!)
        let client = FeiNiuClient(credentials: Credentials())
        let page = try client.parseSearchPage(result) { Track(json: $0) }
        XCTAssertEqual(page.list.count, 1)
        XCTAssertEqual(page.list.first?.guid, "t1")
    }
}
