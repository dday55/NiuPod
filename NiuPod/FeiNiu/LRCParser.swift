import Foundation

/// 一行歌词（含可选逐字时间轴）
struct LyricLine: Identifiable, Sendable, Equatable {
    let id: Int
    /// 起始时间（秒）
    let time: TimeInterval
    let text: String
    /// 译文（同一时间戳的第二行内容，飞牛服务端常把翻译写在重复时间戳行里）
    var translation: String?
    /// 逐字时间轴（`enhanced` 格式 `[mm:ss.xx]<mm:ss.xx>字...`），无则为空
    var words: [LyricWord]

    var hasWordTiming: Bool { !words.isEmpty }
}

struct LyricWord: Sendable, Equatable {
    let time: TimeInterval
    let text: String
}

/// LRC 歌词解析器
///
/// 支持：
/// - 标准 LRC：`[mm:ss.xx]歌词`
/// - 一行多时间戳：`[00:12.00][01:20.00]副歌`
/// - 元信息标签：`[ti:]` `[ar:]` `[al:]` `[offset:±毫秒]`
/// - 双行译文：同一时间戳出现两次时，第二条作为译文合并（与飞牛服务端行为一致）
/// - 逐字（增强）格式：`[mm:ss.xx]<mm:ss.xx>第<mm:ss.xx>一<mm:ss.xx>句`
struct LRCParser {
    struct Result: Sendable {
        var lines: [LyricLine] = []
        var offsetMs: Int = 0
        var title: String?
        var artist: String?
        var album: String?
    }

    static func parse(_ raw: String) -> Result {
        var result = Result()
        var pending: [TimeInterval: Int] = [:]   // 时间戳 → lines 下标（用于合并译文）
        var id = 0

        let tagPattern = #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#
        let metaPattern = #"\[(ti|ar|al|offset|by|re|ve):([^\]]*)\]"#
        let metaRegex = try? NSRegularExpression(pattern: metaPattern, options: .caseInsensitive)
        let tagRegex = try? NSRegularExpression(pattern: tagPattern)

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line).trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)

            // 元信息
            if let m = metaRegex?.firstMatch(in: raw, range: nsRange),
               let keyRange = Range(m.range(at: 1), in: raw),
               let valRange = Range(m.range(at: 2), in: raw) {
                let key = String(raw[keyRange]).lowercased()
                let value = String(raw[valRange]).trimmingCharacters(in: .whitespaces)
                switch key {
                case "ti": result.title = value
                case "ar": result.artist = value
                case "al": result.album = value
                case "offset": result.offsetMs = Int(value) ?? 0
                default: break
                }
                continue
            }

            // 时间戳行
            guard let tagRegex else { continue }
            let matches = tagRegex.matches(in: raw, range: nsRange)
            guard !matches.isEmpty else { continue }

            var times: [TimeInterval] = []
            for m in matches {
                guard let minR = Range(m.range(at: 1), in: raw),
                      let secR = Range(m.range(at: 2), in: raw) else { continue }
                let min = Double(raw[minR]) ?? 0
                let sec = Double(raw[secR]) ?? 0
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound, let fR = Range(m.range(at: 3), in: raw) {
                    let digits = raw[fR]
                    frac = Double("0.\(digits)") ?? 0
                }
                times.append(min * 60 + sec + frac)
            }
            guard !times.isEmpty else { continue }

            // 去掉时间标签后的正文（保留逐字的 <> 标记先提取）
            let body = tagRegex.stringByReplacingMatches(
                in: raw, range: nsRange, withTemplate: ""
            )

            let (text, words) = extractWords(body)

            for time in times.sorted() {
                // 同一时间戳已存在 → 作为译文合并
                if let idx = pending[time] {
                    if !text.isEmpty {
                        result.lines[idx].translation = text
                    }
                    continue
                }
                let line = LyricLine(id: id, time: time, text: text, translation: nil, words: words)
                id += 1
                result.lines.append(line)
                pending[time] = result.lines.count - 1
            }
        }

        // 应用 offset 并按时间排序
        let offsetSec = Double(result.offsetMs) / 1000.0
        result.lines = result.lines
            .map { line in
                LyricLine(
                    id: line.id,
                    time: max(0, line.time - offsetSec),
                    text: line.text,
                    translation: line.translation,
                    words: line.words.map { LyricWord(time: max(0, $0.time - offsetSec), text: $0.text) }
                )
            }
            .sorted { $0.time < $1.time }

        return result
    }

    /// 从正文里剥离逐字标记 `<mm:ss.xx>字`，返回纯文本与逐字时间轴
    private static func extractWords(_ body: String) -> (String, [LyricWord]) {
        let wordPattern = #"<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>\s*([^<]*)"#
        guard let regex = try? NSRegularExpression(pattern: wordPattern) else {
            return (body.trimmingCharacters(in: .whitespaces), [])
        }
        let nsRange = NSRange(body.startIndex..<body.endIndex, in: body)
        let matches = regex.matches(in: body, range: nsRange)
        guard !matches.isEmpty else {
            return (body.trimmingCharacters(in: .whitespaces), [])
        }

        var words: [LyricWord] = []
        var plain = ""
        for m in matches {
            guard let minR = Range(m.range(at: 1), in: body),
                  let secR = Range(m.range(at: 2), in: body),
                  let txtR = Range(m.range(at: 4), in: body) else { continue }
            let min = Double(body[minR]) ?? 0
            let sec = Double(body[secR]) ?? 0
            var frac = 0.0
            if m.range(at: 3).location != NSNotFound, let fR = Range(m.range(at: 3), in: body) {
                frac = Double("0.\(body[fR])") ?? 0
            }
            let text = String(body[txtR])
            words.append(LyricWord(time: min * 60 + sec + frac, text: text))
            plain += text
        }
        return (plain.trimmingCharacters(in: .whitespaces), words)
    }

    /// 当前时间对应的行下标
    static func index(of time: TimeInterval, in lines: [LyricLine]) -> Int {
        guard !lines.isEmpty else { return -1 }
        var low = 0, high = lines.count - 1, result = -1
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}
