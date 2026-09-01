import Foundation

/// 加载阶段的音频流探测。
///
/// 在把地址交给 AVPlayer 之前，先用带认证头的轻量请求（`Range: bytes=0-1`）
/// 验证这条流是否真的可播：地址 scheme 是否受支持、服务端是否返回音频内容
/// 而不是登录页 / 错误页。拿到响应头后立刻取消下载，避免把整个文件拉下来。
/// 这样「不支持的 URL」(-1002) 一类的失败会在加载阶段被过滤掉，
/// 不再由 AVPlayer 报错。
final class StreamProbe: NSObject, URLSessionDelegate, URLSessionDataDelegate, @unchecked Sendable {

    enum Result {
        case ok
        case unsupported
        case unauthorized
        case network
    }

    static func probe(url: URL, headers: [String: String]) async -> Result {
        let probe = StreamProbe()
        return await probe.run(url: url, headers: headers)
    }

    private var continuation: CheckedContinuation<Result, Never>?
    private var session: URLSession?
    private var finished = false
    private let lock = NSLock()

    private func run(url: URL, headers: [String: String]) async -> Result {
        await withCheckedContinuation { cont in
            lock.lock()
            continuation = cont
            lock.unlock()

            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.allHTTPHeaderFields = headers
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            // 只取前 2 字节：足够验证内容类型，又不用下载整个文件
            request.setValue("bytes=0-1", forHTTPHeaderField: "Range")

            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 15
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            session.dataTask(with: request).resume()
        }
    }

    private func finish(_ result: Result) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        session?.invalidateAndCancel()
        session = nil
        cont?.resume(returning: result)
    }

    // 自签名 HTTPS：与登录流程保持一致，信任服务器证书（这里只做探测，
    // 真正播放是否可行由后续 AVPlayer 决定）
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let result: Result
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200, 206:
                let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                if ct.isEmpty || ct.contains("text/html") || ct.contains("application/json")
                    || ct.contains("text/plain") {
                    // 服务端返回的是网页/JSON/纯文本错误页，不是音频 → 不可播
                    result = .unsupported
                } else {
                    result = .ok
                }
            case 401, 403:
                result = .unauthorized
            default:
                result = .unsupported
            }
        } else {
            result = .network
        }
        completionHandler(.cancel)
        finish(result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // 未走到 didReceive 就结束（网络失败 / 超时 / 被取消）→ 网络问题
        finish(.network)
    }
}
