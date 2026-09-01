import Foundation
import OSLog

enum Log {
    private static let logger = Logger(subsystem: "com.niupod", category: "app")

    static func net(_ message: String) {
        #if DEBUG
        logger.debug("[net] \(message, privacy: .private)")
        #endif
    }

    static func info(_ message: String) {
        #if DEBUG
        logger.info("[app] \(message, privacy: .private)")
        #endif
    }

    static func error(_ message: String) {
        logger.error("[err] \(message, privacy: .private)")
    }
}

extension URLSession {
    /// 飞牛专用会话：信任自签名证书 + 手动处理重定向（跟随时会重新带 Cookie）
    static let niupod: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false          // Cookie 完全手动管理
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = TrustingSessionDelegate()
        delegate.followRedirects = false
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()
}
