import Foundation

// MARK: - 宽松类型解析

/// 飞牛服务端存在把数字字段返回成字符串的情况（如 `releaseDate: "1714521600"`），
/// 这里统一做宽容解析。
enum AnyCodable {
    static func int(_ value: Any?) -> Int? {
        if let v = value as? Int { return v }
        if let v = value as? Double { return Int(v) }
        if let v = value as? NSNumber { return v.intValue }
        if let v = value as? String {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return nil }
            if let i = Int(t) { return i }
            if let d = Double(t) { return Int(d) }
        }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? NSNumber { return v.doubleValue }
        if let v = value as? String {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : Double(t)
        }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let v = value as? Bool { return v }
        if let v = value as? Int { return v != 0 }
        if let v = value as? NSNumber { return v.boolValue }
        if let v = value as? String {
            switch v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        if let v = value as? String { return v }
        if let v = value as? Int { return String(v) }
        if let v = value as? NSNumber { return v.stringValue }
        return nil
    }
}

// MARK: - 网络错误

enum FeiNiuError: LocalizedError {
    case invalidURL(String)
    case httpStatus(Int, String?)
    case server(code: Int, msg: String)
    case network(underlying: Error)
    case decoding(String)
    case cancelled
    case unauthorized
    case allCandidatesFailed([ProbeCandidateResult])

    /// 底层错误（用于判断是否值得触发链路自动切换）
    var underlyingError: Error? {
        if case .network(let e) = self { return e }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL(let u):
            return "无效地址：\(u)"
        case .httpStatus(let s, let m):
            return "HTTP \(s)\(m.map { " — \($0)" } ?? "")"
        case .server(_, let msg):
            return msg
        case .network(let e):
            return "网络异常：\(e.localizedDescription)"
        case .decoding(let m):
            return "数据解析失败：\(m)"
        case .cancelled:
            return "已取消"
        case .unauthorized:
            return "登录已失效，请重新登录"
        case .allCandidatesFailed(let results):
            let detail = results.filter { !$0.isReachable }.prefix(3)
                .map { "\($0.description)：\($0.error ?? "不可达")" }
                .joined(separator: "；")
            return detail.isEmpty ? "所有链路均不可达" : "所有链路均不可达。\(detail)"
        }
    }
}

// MARK: - 自签名证书 + 手动重定向

/// 飞牛 NAS 直连（尤其 HTTPS 端口）普遍使用自签名证书，系统默认会拒绝；
/// 同时服务器常配「HTTP 强制跳转 HTTPS」的 302 规则，自动跟随会丢掉 `Cookie`
/// 头，导致 `music-token` 不被携带。这里统一处理这两件事。
final class TrustingSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {

    /// 是否信任自签名证书（默认开启，设置页可关闭）
    var allowSelfSigned: Bool = true

    /// 是否禁用自动重定向（默认禁用，由调用方手动跟随以保留 Cookie）
    var followRedirects: Bool = false

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard allowSelfSigned,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // 无论证书是否可信都接受：飞牛直连几乎必然是自签名/自建 CA
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// 阻断自动重定向，把 3xx 原样交给调用方处理（跟随时会重新带上 Cookie）
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(followRedirects ? request : nil)
    }
}

/// 一次 HTTP 交互的完整结果（含 3xx 原始信息，供重定向/强制跳转判断使用）
struct HTTPResult: Sendable {
    let status: Int
    let headers: [String: String]
    let data: Data
    let finalURL: URL

    var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    var text: String? {
        String(data: data, encoding: .utf8)
    }
}
