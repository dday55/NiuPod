import Foundation

/// FN Connect 中继服务（FNID → 实际连接参数）
///
/// 这是「飞牛连接」的第一步：仅凭一个 FNID，向飞牛的中枢服务换取这台 NAS
/// 当前所有可用链路（内网 IP / 公网 v4 / 公网 v6 / 中继域名 + 端口）。
///
/// 接口：`POST https://5ddd.com/api/v1/fn/con`
/// 请求体：`{"fnId":"xxxxxxxx"}`
/// 请求头：`authx: nonce=<6位>&timestamp=<毫秒>&sign=<md5>`
enum FnConnectAPI {
    static let host = "https://5ddd.com"
    static let path = "/api/v1/fn/con"

    /// 签名前缀常量（与飞牛各端客户端一致）
    private static let authxPrefix = "NDzZTVxnRKP8Z0jXg1VAMonaG8akvh"
    private static let apiKey = "zIGtkc3dqZnJpd29qZXJqa2w7c"

    // MARK: - authx 签名

    /// 计算 authx 请求头。
    ///
    /// 算法（注意 `url` 必须传**相对路径**，服务端签名校验只用路径部分）：
    /// ```
    /// raw  = PREFIX_url_nonce_timestamp_md5(请求体JSON)_apiKey
    /// sign = md5(raw)
    /// authx = "nonce=<nonce>&timestamp=<timestamp>&sign=<sign>"
    /// ```
    /// 其中 nonce 为 6 位十进制随机数，timestamp 为毫秒时间戳。
    static func authx(method: String, url: String, bodyJSON: String) -> String {
        let content = method.lowercased() == "get" ? bodyJSON : bodyJSON
        let nonce = String(format: "%06d", Int.random(in: 100_000...999_999))
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        let raw = [
            authxPrefix,
            url,
            nonce,
            timestamp,
            MD5.hex(content),
            apiKey,
        ].joined(separator: "_")
        let sign = MD5.hex(raw)
        return "nonce=\(nonce)&timestamp=\(timestamp)&sign=\(sign)"
    }

    // MARK: - 查询

    /// 用 FNID 换取连接参数
    static func fetchConnectionParams(
        fnId: String,
        session: URLSession = .shared
    ) async throws -> FnConnectionParams {
        guard let url = URL(string: host + path) else {
            throw FeiNiuError.invalidURL(host + path)
        }
        let bodyJSON = DartJSON.encode(["fnId": fnId])
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authx(method: "post", url: path, bodyJSON: bodyJSON), forHTTPHeaderField: "authx")
        request.httpBody = Data(bodyJSON.utf8)

        Log.net("[FnConnect] POST \(host + path) body=\(bodyJSON)")

        let (data, response) = try await session.data(for: request)
        guard response is HTTPURLResponse else {
            throw FeiNiuError.network(underlying: URLError(.badServerResponse))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FeiNiuError.decoding(String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        let code = AnyCodable.int(json["code"]) ?? -1
        guard code == 0, let dataObj = json["data"] as? [String: Any] else {
            let msg = AnyCodable.string(json["msg"]) ?? "FNID 查询失败，请检查输入"
            throw FeiNiuError.server(code: code, msg: msg)
        }
        Log.net("[FnConnect] OK → \(dataObj)")
        return FnConnectionParams(json: dataObj)
    }
}

// MARK: - 与 Dart jsonEncode 兼容的确定性 JSON 序列化

/// authx 签名要对**请求体的字节**取 MD5，因此序列化结果必须与飞牛其他客户端
/// 完全一致。Foundation 的 `JSONSerialization` 会额外转义 `/` 等字符，与 Dart
/// 的 `jsonEncode` 不一致会导致签名失败，这里手写一份最小但等价的实现：
/// 只转义 `"`、`\` 和控制字符，其余（含 `/` 与非 ASCII）原样输出。
enum DartJSON {
    static func encode(_ value: Any) -> String {
        switch value {
        case let v as String:
            "\"" + escape(v) + "\""
        case let v as Bool:
            v ? "true" : "false"
        case let v as Int:
            String(v)
        case let v as Double:
            String(v)
        case is NSNull:
            "null"
        case let v as [Any]:
            "[" + v.map { encode($0) }.joined(separator: ",") + "]"
        case let v as [String: Any]:
            // Dart 的 Map 保持插入顺序；单键场景下与排序结果一致
            "{" + v.map { "\"\(escape($0.key))\":\(encode($0.value))" }.joined(separator: ",") + "}"
        default:
            "null"
        }
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
