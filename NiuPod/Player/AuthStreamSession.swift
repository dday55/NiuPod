import AVFoundation
import Foundation
import MobileCoreServices
import UniformTypeIdentifiers

/// 带认证头的流式下载会话
///
/// `AVPlayer` 直接播 URL 时无法携带自定义请求头，而飞牛的音频流要求
/// `Cookie: music-token=...`。这里是把 URL 换成自定义 scheme，由
/// `AVAssetResourceLoaderDelegate` 接管请求，用可控的 `URLSession` 补上
/// Cookie 再取数据。
///
/// > 注意：当前播放已改为「真实 HTTP(S) URL + `AVURLAssetHTTPHeaderFieldsKey`
/// > 注入请求头」，并在加载阶段先探测可播性；自定义 scheme 在部分 iOS 上会被
/// > CoreMedia 直接判为「不支持的 URL」(-1002)。本文件保留作为自签名 HTTPS
/// > 等场景的参考实现，AudioPlayer 不再自动使用。
///
/// 这里用一个共享会话 + taskIdentifier 路由：既能统一管理自签名证书信任，
/// 又能把数据事件分发回对应的 AVAssetResourceLoadingRequest。
final class AuthStreamSession: NSObject, URLSessionDelegate, URLSessionDataDelegate {

    static let shared = AuthStreamSession()

    private var handlers: [Int: StreamHandler] = [:]
    private let lock = NSLock()

    lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 音频流要边下边播，等待缓冲的策略交给 AVPlayer 控制
        config.networkServiceType = .responsiveAV
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func register(_ handler: StreamHandler, for task: URLSessionDataTask) {
        lock.lock(); handlers[task.taskIdentifier] = handler; lock.unlock()
    }

    func remove(_ task: URLSessionDataTask) {
        lock.lock(); handlers.removeValue(forKey: task.taskIdentifier); lock.unlock()
    }

    func cancel(taskIdentifier: Int) {
        session.getAllTasks { tasks in
            tasks.first { $0.taskIdentifier == taskIdentifier }?.cancel()
        }
        lock.lock(); handlers.removeValue(forKey: taskIdentifier); lock.unlock()
    }

    // MARK: - 证书

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

    // MARK: - 数据事件

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let handler = handlers[dataTask.taskIdentifier]
        lock.unlock()
        handler?.didReceive(response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let handler = handlers[dataTask.taskIdentifier]
        lock.unlock()
        handler?.didReceive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let handler = handlers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        handler?.didComplete(error)
    }
}

// MARK: - 单个加载请求的数据泵

final class StreamHandler {
    private let loadingRequest: AVAssetResourceLoadingRequest
    /// 真实音频地址（用于在服务端没给 Content-Type 时按扩展名推断格式）
    private let realURL: URL
    private(set) var dataTask: URLSessionDataTask?
    private var infoFilled = false
    /// 收到响应头之前先攒着的数据（contentInformationRequest 必须先填）
    private var pending = Data()

    init(loadingRequest: AVAssetResourceLoadingRequest, realURL: URL) {
        self.loadingRequest = loadingRequest
        self.realURL = realURL
    }

    func start(request: URLRequest) {
        let task = AuthStreamSession.shared.session.dataTask(with: request)
        dataTask = task
        AuthStreamSession.shared.register(self, for: task)
        task.resume()
    }

    func cancel() {
        if let task = dataTask {
            AuthStreamSession.shared.cancel(taskIdentifier: task.taskIdentifier)
        }
    }

    func didReceive(_ response: URLResponse) {
        guard let http = response as? HTTPURLResponse, let info = loadingRequest.contentInformationRequest else {
            infoFilled = true
            return
        }

        // 内容类型：服务端 Content-Type 优先；识别不了（如 application/octet-stream）
        // 再按真实 URL 扩展名推断，最后才兜底 mp3。类型填错会导致 AVPlayer 有进度但不出声。
        let mime = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
            .components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces)
        if let mime, !mime.isEmpty,
           let utType = UTType(mimeType: mime),
           utType.conforms(to: .audiovisualContent) || utType.conforms(to: .audio),
           let uti = utType.identifier as String? {
            info.contentType = uti
        } else if let extType = Self.inferredUTI(for: realURL) {
            info.contentType = extType
        } else {
            info.contentType = AVFileType.mp3.rawValue
        }
        info.isByteRangeAccessSupported = http.statusCode == 206
            || http.value(forHTTPHeaderField: "Accept-Ranges") == "bytes"
            || http.value(forHTTPHeaderField: "Content-Range") != nil

        // 有 Content-Range 时优先用它给总长度；没有时 AVPlayer 会按流式处理
        var total: Int64 = 0
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let tail = range.components(separatedBy: "/").last,
           let v = Int64(tail.trimmingCharacters(in: .whitespaces)) {
            total = v
        } else if let len = http.value(forHTTPHeaderField: "Content-Length"), let v = Int64(len) {
            total = v
        }
        info.contentLength = total > 0 ? total : 0

        infoFilled = true
        if !pending.isEmpty {
            loadingRequest.dataRequest?.respond(with: pending)
            pending.removeAll(keepingCapacity: true)
        }
    }

    /// 按真实 URL 扩展名推断 UTI（mp3 / m4a / flac / wav …）
    static func inferredUTI(for url: URL) -> String? {
        let ext = url.pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return nil }
        return type.identifier
    }

    func didReceive(_ data: Data) {
        if !infoFilled {
            pending.append(data)
            return
        }
        loadingRequest.dataRequest?.respond(with: data)
    }

    func didComplete(_ error: Error?) {
        if let error {
            loadingRequest.finishLoading(with: error)
        } else {
            loadingRequest.finishLoading()
        }
    }
}

// MARK: - Resource Loader Delegate

/// 把 `niupod-stream://` 的加载请求转成携带 Cookie 的真实 HTTP 请求
final class CookieAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {

    static let scheme = "niupod-stream"

    /// 真实音频流地址
    let realURL: URL
    /// 认证头（Cookie / 安全码）
    let headers: [String: String]

    private var handlers: [AVAssetResourceLoadingRequest: StreamHandler] = [:]
    private let lock = NSLock()

    init(realURL: URL, headers: [String: String]) {
        self.realURL = realURL
        self.headers = headers
        super.init()
    }

    /// 构造供 AVURLAsset 使用的自定义 scheme URL
    static func placeholderURL(for guid: String) -> URL? {
        // 自定义 scheme 必须带合法 host：`niupod-stream:///...` 的 host 是空的，
        // 部分 iOS 上 AVFoundation 会直接判为「不支持的 URL」，连 resourceLoader
        // 都不会调用。host 用 127.0.0.1：是合法 IP 字面量，也不会像 `.local` 那样
        // 触发 mDNS 解析。resourceLoader 里实际请求的是 realURL，这里只当占位。
        // 用 .mp3 扩展名给 AVFoundation 明确的媒体类型提示；
        // 真实格式仍以响应头 contentInformationRequest 为准。
        URL(string: "\(scheme)://127.0.0.1/track/\(guid).mp3")
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        var request = URLRequest(url: realURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.allHTTPHeaderFields = headers
        // 禁止压缩：音频流一旦被 gzip 包装，AVPlayer 会拿不到可解码的裸音频
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        // 按 AVPlayer 的要求拼 Range
        if let dataReq = loadingRequest.dataRequest {
            let offset = dataReq.requestedOffset
            if dataReq.requestsAllDataToEndOfResource {
                request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            } else {
                let end = offset + Int64(dataReq.requestedLength) - 1
                request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            }
        }

        let handler = StreamHandler(loadingRequest: loadingRequest, realURL: realURL)
        lock.lock()
        handlers[loadingRequest] = handler
        lock.unlock()
        handler.start(request: request)
        Log.net("[Stream] → \(request.url?.absoluteString ?? "") Range=\(request.value(forHTTPHeaderField: "Range") ?? "-")")
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        lock.lock()
        let handler = handlers.removeValue(forKey: loadingRequest)
        lock.unlock()
        handler?.cancel()
    }
}
