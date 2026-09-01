import Foundation

/// 演示模式数据
///
/// 没有飞牛 NAS 也能看到完整的 iPod 界面：登录页底部点「演示模式」即可进入。
/// 数据全部为本地占位内容，不请求网络，播放不可用。
enum DemoData {

    private struct Seed {
        let title: String
        let album: String
        let artist: String
        let year: Int
        let durationMs: Int
        var hasLyric = true
    }

    private static let seeds: [Seed] = [
        Seed(title: "夜航西飞", album: "候鸟电台", artist: "林岸", year: 2019, durationMs: 254_000),
        Seed(title: "雨落无声", album: "候鸟电台", artist: "林岸", year: 2019, durationMs: 231_000),
        Seed(title: "潮汐信号", album: "候鸟电台", artist: "林岸", year: 2019, durationMs: 288_000),
        Seed(title: "午夜站台", album: "候鸟电台", artist: "林岸", year: 2019, durationMs: 205_000),
        Seed(title: "白色信封", album: "候鸟电台", artist: "林岸", year: 2019, durationMs: 243_000),

        Seed(title: "橘子汽水", album: "夏日限定", artist: "汽水少年", year: 2021, durationMs: 198_000),
        Seed(title: "操场晚风", album: "夏日限定", artist: "汽水少年", year: 2021, durationMs: 212_000),
        Seed(title: "单车与海", album: "夏日限定", artist: "汽水少年", year: 2021, durationMs: 226_000),
        Seed(title: "蝉鸣十七", album: "夏日限定", artist: "汽水少年", year: 2021, durationMs: 189_000),

        Seed(title: "旧巷灯火", album: "城南手记", artist: "周未眠", year: 2017, durationMs: 276_000),
        Seed(title: "铁皮盒子", album: "城南手记", artist: "周未眠", year: 2017, durationMs: 264_000),
        Seed(title: "长夜将尽", album: "城南手记", artist: "周未眠", year: 2017, durationMs: 301_000),
        Seed(title: "写给明天的信", album: "城南手记", artist: "周未眠", year: 2017, durationMs: 258_000, hasLyric: false),

        Seed(title: "山谷回声", album: "无人之地", artist: "何以", year: 2020, durationMs: 322_000),
        Seed(title: "雾中列车", album: "无人之地", artist: "何以", year: 2020, durationMs: 295_000),
        Seed(title: "极光观测", album: "无人之地", artist: "何以", year: 2020, durationMs: 341_000),
        Seed(title: "雪线之上", album: "无人之地", artist: "何以", year: 2020, durationMs: 278_000),

        Seed(title: "清晨六点", album: "晨间练习", artist: "苏黎", year: 2022, durationMs: 187_000),
        Seed(title: "一杯温水", album: "晨间练习", artist: "苏黎", year: 2022, durationMs: 194_000),
        Seed(title: "通勤路上", album: "晨间练习", artist: "苏黎", year: 2022, durationMs: 203_000),
        Seed(title: "窗台植物", album: "晨间练习", artist: "苏黎", year: 2022, durationMs: 176_000, hasLyric: false),

        Seed(title: "蓝色房间", album: "单曲集", artist: "林岸", year: 2023, durationMs: 219_000),
        Seed(title: "未寄出的信", album: "单曲集", artist: "周未眠", year: 2023, durationMs: 247_000),
        Seed(title: "末班地铁", album: "单曲集", artist: "汽水少年", year: 2023, durationMs: 233_000),
        Seed(title: "冬至", album: "单曲集", artist: "何以", year: 2023, durationMs: 312_000),
    ]

    private static func guid(_ seed: String) -> String {
        // 用内容生成稳定的 guid，保证 Identifiable 与收藏逻辑一致
        MD5.hex(seed)
    }

    // MARK: - 实体

    static let artists: [Artist] = {
        let names = ["林岸", "汽水少年", "周未眠", "何以", "苏黎"]
        return names.map { name in
            Artist(json: [
                "guid": guid("artist-\(name)"),
                "name": name,
                "trackCount": seeds.filter { $0.artist == name }.count,
                "albumCount": Set(seeds.filter { $0.artist == name }.map(\.album)).count,
            ])
        }
    }()

    static let albums: [Album] = {
        let names = ["候鸟电台", "夏日限定", "城南手记", "无人之地", "晨间练习", "单曲集"]
        return names.map { name in
            Album(json: [
                "guid": guid("album-\(name)"),
                "name": name,
                "trackCount": seeds.filter { $0.album == name }.count,
                "createdAt": 1_600_000_000,
            ])
        }
    }()

    static let tracks: [Track] = {
        seeds.map { seed in
            Track(json: [
                "guid": guid("track-\(seed.artist)-\(seed.album)-\(seed.title)"),
                "title": seed.title,
                "duration": seed.durationMs,
                "year": seed.year,
                "createdAt": 1_600_000_000,
                "updatedAt": 1_600_000_000,
                "hasLyric": seed.hasLyric,
                "album": [
                    "guid": guid("album-\(seed.album)"),
                    "name": seed.album,
                ],
                "artists": [[
                    "guid": guid("artist-\(seed.artist)"),
                    "name": seed.artist,
                ]],
            ])
        }
    }()

    static let playlists: [Playlist] = [
        Playlist(json: ["guid": guid("pl-night"), "name": "深夜通勤",
                        "trackCount": 8, "createdAt": 1_600_000_000, "updatedAt": 1_600_000_000]),
        Playlist(json: ["guid": guid("pl-morning"), "name": "清晨启动",
                        "trackCount": 6, "createdAt": 1_600_000_000, "updatedAt": 1_600_000_000]),
        Playlist(json: ["guid": guid("pl-focus"), "name": "专注白噪音",
                        "trackCount": 5, "createdAt": 1_600_000_000, "updatedAt": 1_600_000_000]),
    ]

    static let genres: [Genre] = [
        Genre(json: ["guid": guid("g-folk"), "name": "民谣", "trackCount": 9]),
        Genre(json: ["guid": guid("g-pop"), "name": "流行", "trackCount": 8]),
        Genre(json: ["guid": guid("g-ambient"), "name": "氛围", "trackCount": 7]),
    ]

    static let favorites: [Track] = Array(tracks.prefix(4))

    // MARK: - 演示歌词

    static func demoLyrics(for track: Track) -> String {
        """
        [ti:\(track.title)]
        [ar:\(track.artistName)]
        [al:\(track.album.name)]
        [00:00.00]《\(track.title)》
        [00:04.50]（演示歌词）
        [00:10.00]第一行歌词在这里
        [00:10.00]First line of the lyrics
        [00:16.00]第二行跟着节拍走
        [00:22.50]第三行慢慢升起来
        [00:29.00]副歌部分高亮显示
        [00:36.00]转盘可以快进快退
        [00:43.00]中心键切换显示模式
        [00:50.00]这里是演示数据
        [00:57.00]连接真实 NAS 后
        [01:04.00]就能播放你的音乐库
        """
    }
}
