import UIKit

/// 封面加载：带认证头下载 + 内存/磁盘二级缓存
///
/// 飞牛的封面接口要求 `Cookie: music-token`，无法用普通图片库直连，
/// 这里自己发请求并落盘缓存（按 coverId 命名，URL 统一 800px 保证命中率）。
enum ArtworkLoader {
    private static let memory = NSCache<NSString, UIImage>()

    private static var cacheDirectory: URL? {
        guard let base = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let dir = base.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func image(for coverId: String?, using client: FeiNiuClient, size: Int = 800) async -> UIImage? {
        guard let coverId, !coverId.isEmpty,
              let url = client.coverURL(coverId: coverId, size: size) else { return nil }

        if let cached = memory.object(forKey: coverId as NSString) { return cached }

        let file = cacheDirectory?.appendingPathComponent("\(coverId)@\(size).img")
        if let file, let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            memory.setObject(img, forKey: coverId as NSString)
            return img
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.allHTTPHeaderFields = client.resourceHeaders
        guard let (data, response) = try? await URLSession.niupod.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty,
              let img = UIImage(data: data) else { return nil }

        memory.setObject(img, forKey: coverId as NSString)
        if let file { try? data.write(to: file) }
        return img
    }

    static func clearMemoryCache() {
        memory.removeAllObjects()
    }

    static func clearDiskCache() {
        guard let dir = cacheDirectory else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
