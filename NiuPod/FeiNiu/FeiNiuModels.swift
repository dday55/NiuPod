import Foundation

// MARK: - 通用响应封装

/// 飞牛 API 统一响应壳：`{code, msg, data}`，`code == 0` 为成功。
struct FeiNiuResponse<T> {
    let code: Int
    let msg: String
    let data: T?

    var isSuccess: Bool { code == 0 }

    init(json: [String: Any], parse: (([String: Any]) -> T?)?) {
        code = AnyCodable.int(json["code"]) ?? -1
        msg = AnyCodable.string(json["msg"]) ?? ""
        if let obj = json["data"] as? [String: Any] {
            data = parse?(obj)
        } else if let arr = json["data"] as? [Any], let parse {
            data = parse(["list": arr])
        } else {
            data = nil
        }
    }
}

struct PageData<T> {
    let list: [T]
    let total: Int

    init(json: [String: Any], map: (([String: Any]) -> T)) {
        list = ((json["list"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []).map(map)
        total = AnyCodable.int(json["total"]) ?? list.count
    }

    init(list: [T], total: Int) {
        self.list = list
        self.total = total
    }
}

// MARK: - 音频规格

struct AudioSpec {
    let bitDepth: Int?
    let sampleRate: Int?
    let channel: Int?
    let bitrate: Int?
    let codec: String?
    let format: String?
    let duration: Int?
    let size: Int?
    let path: String?

    init(json: [String: Any]?) {
        guard let json else {
            bitDepth = nil; sampleRate = nil; channel = nil; bitrate = nil
            codec = nil; format = nil; duration = nil; size = nil; path = nil
            return
        }
        bitDepth = AnyCodable.int(json["bitDepth"])
        sampleRate = AnyCodable.int(json["sampleRate"])
        channel = AnyCodable.int(json["channel"])
        bitrate = AnyCodable.int(json["bitrate"])
        codec = AnyCodable.string(json["codec"])
        format = AnyCodable.string(json["format"])
        duration = AnyCodable.int(json["duration"])
        size = AnyCodable.int(json["size"])
        path = AnyCodable.string(json["path"])
    }

    /// 如 `FLAC 44.1kHz 16bit 921kbps`
    var displayText: String {
        var parts: [String] = []
        if let format, !format.isEmpty { parts.append(format.uppercased()) }
        if let sampleRate, sampleRate > 0 { parts.append(String(format: "%.1fkHz", Double(sampleRate) / 1000)) }
        if let bitDepth, bitDepth > 0 { parts.append("\(bitDepth)bit") }
        if let bitrate, bitrate > 0 { parts.append("\(Int(Double(bitrate) / 1000))kbps") }
        return parts.joined(separator: " ")
    }
}

// MARK: - 曲目

struct Track: Identifiable, Hashable, Sendable {
    let guid: String
    let title: String
    let coverId: String?
    let year: Int?
    let discNo: Int?
    let trackNo: Int?
    /// 时长（毫秒）
    let duration: Int?
    let isCue: Bool
    let createdAt: Int
    let updatedAt: Int
    let album: Album
    let artists: [Artist]
    var isFavorite: Bool
    let hasLyric: Bool?
    let audioSpec: AudioSpec?
    let isrc: String?
    let genres: [Genre]
    /// 音频文件已被删除（失效歌曲，直接播放会失败）
    let isAudioFileDeleted: Bool

    var id: String { guid }

    /// 显示用歌手名
    var artistName: String {
        artists.map(\.name).joined(separator: " / ").nilIfEmpty ?? "未知歌手"
    }

    /// 时长（秒）
    var durationSeconds: Double {
        Double(duration ?? 0) / 1000
    }

    init(json: [String: Any]) {
        guid = AnyCodable.string(json["guid"]) ?? ""
        title = AnyCodable.string(json["title"]) ?? "未知标题"
        coverId = AnyCodable.string(json["coverId"])
        year = AnyCodable.int(json["year"])
        discNo = AnyCodable.int(json["discNo"])
        trackNo = AnyCodable.int(json["trackNo"])
        duration = AnyCodable.int(json["duration"])
        isCue = AnyCodable.bool(json["isCue"]) ?? false
        createdAt = AnyCodable.int(json["createdAt"]) ?? 0
        updatedAt = AnyCodable.int(json["updatedAt"]) ?? 0
        album = Album(json: (json["album"] as? [String: Any]) ?? [:])
        artists = ((json["artists"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []).map(Artist.init)
        isFavorite = AnyCodable.bool(json["isFavorite"]) ?? false
        hasLyric = AnyCodable.bool(json["hasLyric"])
        audioSpec = AudioSpec(json: json["audioSpec"] as? [String: Any])
        isrc = AnyCodable.string(json["isrc"])
        genres = ((json["genres"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []).map(Genre.init)
        // 失效歌曲：`accessStatus == 3` 表示音频文件缺失（歌单接口不返回删除标记，靠它判断）
        let status = AnyCodable.int(json["accessStatus"])
        isAudioFileDeleted = (AnyCodable.bool(json["audioFileDeleted"]) ?? false)
            || (AnyCodable.bool(json["isAudioFileDeleted"]) ?? false)
            || status == 3
    }

    func hash(into hasher: inout Hasher) { hasher.combine(guid) }
    static func == (lhs: Track, rhs: Track) -> Bool { lhs.guid == rhs.guid }
}

// MARK: - 可播放性

extension Track {
    /// AVPlayer 明确支持的容器/编码（小写首 token）。
    /// 不在白名单里的格式（APE / WMA / OGG / DSD 等）真机播不了，直接过滤。
    private static let supportedAudioFormats: Set<String> = [
        "mp3", "mpeg", "mpga", "aac", "m4a", "mp4", "alac", "apple",
        "flac", "wav", "wave", "pcm", "lpcm", "aiff", "aif", "caf",
        "m4b", "m4r",
    ]

    /// 音频格式是否属于 AVPlayer 无法解码的类型。
    /// 优先看 audioSpec.format，其次 codec；两者都为空时视为可播放（不过滤）。
    var isFormatUnsupported: Bool {
        let tokens = [audioSpec?.format, audioSpec?.codec]
            .compactMap { $0 }
            .map { $0.lowercased() }
            .flatMap { $0.components(separatedBy: CharacterSet.alphanumerics.inverted) }
            .filter { !$0.isEmpty }
        guard let primary = tokens.first else { return false }
        return !Self.supportedAudioFormats.contains(primary)
    }

    /// 是否能播放：文件存在且格式受支持
    var isPlayable: Bool {
        !isAudioFileDeleted && !isFormatUnsupported
    }
}

// MARK: - 专辑

struct Album: Identifiable, Hashable, Sendable {
    let guid: String
    let name: String
    let coverId: String?
    let releaseDate: Int?
    let trackCount: Int?
    let createdAt: Int?

    var id: String { guid }

    init(json: [String: Any]) {
        guid = AnyCodable.string(json["guid"]) ?? ""
        name = AnyCodable.string(json["name"]) ?? "未知专辑"
        coverId = AnyCodable.string(json["coverId"])
        releaseDate = AnyCodable.int(json["releaseDate"])
        trackCount = AnyCodable.int(json["trackCount"])
        createdAt = AnyCodable.int(json["createdAt"])
    }

    init(guid: String, name: String, coverId: String?, trackCount: Int? = nil) {
        self.guid = guid
        self.name = name
        self.coverId = coverId
        self.trackCount = trackCount
        self.releaseDate = nil
        self.createdAt = nil
    }
}

// MARK: - 歌手

struct Artist: Identifiable, Hashable, Sendable {
    let guid: String
    let name: String
    let coverId: String?
    let trackCount: Int?
    let albumCount: Int?

    var id: String { guid }

    init(json: [String: Any]) {
        guid = AnyCodable.string(json["guid"]) ?? ""
        name = AnyCodable.string(json["name"]) ?? "未知歌手"
        coverId = AnyCodable.string(json["coverId"])
        trackCount = AnyCodable.int(json["trackCount"])
        albumCount = AnyCodable.int(json["albumCount"])
    }
}

// MARK: - 歌单

struct Playlist: Identifiable, Hashable, Sendable {
    let guid: String
    let name: String
    let coverId: String?
    let trackCount: Int
    let createdAt: Int
    let updatedAt: Int

    var id: String { guid }

    init(json: [String: Any]) {
        guid = AnyCodable.string(json["guid"]) ?? ""
        name = AnyCodable.string(json["name"]) ?? "未知歌单"
        coverId = AnyCodable.string(json["coverId"])
        trackCount = AnyCodable.int(json["trackCount"]) ?? 0
        createdAt = AnyCodable.int(json["createdAt"]) ?? 0
        updatedAt = AnyCodable.int(json["updatedAt"]) ?? 0
    }
}

// MARK: - 风格

struct Genre: Identifiable, Hashable, Sendable {
    let guid: String
    let name: String
    let coverId: String?
    let trackCount: Int

    var id: String { guid }

    init(json: [String: Any]) {
        guid = AnyCodable.string(json["guid"]) ?? ""
        name = AnyCodable.string(json["name"]) ?? "未知风格"
        coverId = AnyCodable.string(json["coverId"])
        trackCount = AnyCodable.int(json["trackCount"]) ?? 0
    }
}

// MARK: - 歌词

struct Lyric: Sendable {
    let guid: String
    let content: String
    let isLRC: Bool
    let offset: Int?

    init(json: [String: Any]) {
        guid = AnyCodable.string(json["guid"]) ?? ""
        content = AnyCodable.string(json["content"]) ?? ""
        isLRC = AnyCodable.bool(json["isLRC"]) ?? true
        offset = AnyCodable.int(json["offset"])
    }
}

struct LyricResponse: Sendable {
    let list: [Lyric]
    let preferred: String?

    init(json: [String: Any]) {
        list = ((json["list"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []).map(Lyric.init)
        preferred = AnyCodable.string(json["preferred"])
    }

    /// 首选歌词文本（有 preferred 用 preferred，否则第一条）
    var preferredContent: String? {
        if let preferred, let hit = list.first(where: { $0.guid == preferred }) { return hit.content }
        return list.first?.content
    }
}

// MARK: - 登录

struct LoginResult: Sendable {
    let userToken: String
    let username: String?
    let userGUID: String?
    let role: String?

    init(json: [String: Any]) {
        userToken = AnyCodable.string(json["userToken"]) ?? ""
        let user = json["user"] as? [String: Any]
        username = user.flatMap { AnyCodable.string($0["name"]) }
        userGUID = user.flatMap { AnyCodable.string($0["guid"]) }
        role = user.flatMap { AnyCodable.string($0["role"]) }
    }
}

// MARK: - 搜索结果

struct SearchResults: Sendable {
    let tracks: [Track]
    let albums: [Album]
    let artists: [Artist]

    static let empty = SearchResults(tracks: [], albums: [], artists: [])
}

// MARK: - 小工具

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
