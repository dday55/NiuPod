import Foundation

// MARK: - 候选链路分组

/// 候选链路分组（决定探测优先级）
enum ProbeCandidateGroup: String, CaseIterable, Codable, Sendable {
    case `internal`      // 内网 IPv4 直连
    case publicIPv6      // 公网 IPv6 直连
    case publicIPv4      // 公网 IPv4 直连
    case relay           // FN Connect 中继（*.5ddd.com）

    var title: String {
        switch self {
        case .internal: "内网"
        case .publicIPv6: "公网 IPv6"
        case .publicIPv4: "公网 IPv4"
        case .relay: "中继"
        }
    }

    var subtitle: String {
        switch self {
        case .internal: "局域网内直连，延迟最低"
        case .publicIPv6: "公网 IPv6 直连"
        case .publicIPv4: "公网 IPv4 直连"
        case .relay: "中继转发，兜底链路"
        }
    }

    var sortOrder: Int {
        switch self {
        case .internal: 0
        case .publicIPv6: 1
        case .publicIPv4: 2
        case .relay: 3
        }
    }
}

/// 默认连接优先级顺序
let kDefaultConnectionOrder: [ProbeCandidateGroup] = [
    .internal, .publicIPv6, .publicIPv4, .relay
]

// MARK: - FN Connect 接口返回的连接参数

/// FN 接口（`POST https://5ddd.com/api/v1/fn/con`）返回的连接参数。
///
/// 实际响应示例：
/// ```json
/// {"ddns":null,
///  "ipv4":["192.168.11.100"],
///  "ipv6":[],
///  "publicIpv4":["120.239.1.2"],
///  "publicIpv6":["2409:..."],
///  "fn":["xxxxx.5ddd.com:443"],
///  "port":{"httpsPort":5667,"httpPort":5666},
///  "checkSum":"24756","ver":"3.0.0","forbbidPublicIpv6":false}
/// ```
struct FnConnectionParams: Sendable {
    var internalIPv4s: [String] = []
    var publicIPv4s: [String] = []
    var publicIPv6s: [String] = []
    var httpsPort: Int = 5667
    var httpPort: Int = 5666
    var relayAddresses: [String] = []

    init() {}

    init(json: [String: Any]) {
        internalIPv4s = Self.stringArray(json["ipv4"])
        publicIPv4s = Self.stringArray(json["publicIpv4"])
        publicIPv6s = Self.stringArray(json["publicIpv6"])
        relayAddresses = Self.stringArray(json["fn"])
        if let port = json["port"] as? [String: Any] {
            httpsPort = AnyCodable.int(port["httpsPort"]) ?? 5667
            httpPort = AnyCodable.int(port["httpPort"]) ?? 5666
        }
    }

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }
}

// MARK: - 候选链路

/// 单条候选链路（构建阶段的规格描述）
struct ProbeCandidateSpec: Sendable {
    let address: String
    let description: String
    let group: ProbeCandidateGroup
    let ipLabel: String?
    let relayMode: Bool
    /// 中继链路固定 443，构造时显式传入；IP 直连默认 false
    init(address: String, description: String, group: ProbeCandidateGroup,
         ipLabel: String?, relayMode: Bool = false) {
        self.address = address
        self.description = description
        self.group = group
        self.ipLabel = ipLabel
        self.relayMode = relayMode
    }
}

/// 单条候选链路探测结果（用于「连接诊断」页完整展示）
struct ProbeCandidateResult: Sendable, Identifiable {
    var id: String { address }
    let address: String
    let description: String
    let group: ProbeCandidateGroup
    let ipLabel: String?
    let isRelay: Bool
    let isReachable: Bool
    let error: String?
    /// 探测耗时（毫秒）
    let elapsedMs: Int

    init(spec: ProbeCandidateSpec, isReachable: Bool, error: String? = nil, elapsedMs: Int = 0) {
        self.address = spec.address
        self.description = spec.description
        self.group = spec.group
        self.ipLabel = spec.ipLabel
        self.isRelay = spec.relayMode
        self.isReachable = isReachable
        self.error = error
        self.elapsedMs = elapsedMs
    }
}

/// 最终探测结论
struct ConnectionProbeResult: Sendable {
    let serverUrl: String
    let probeMethod: String
    let isRelay: Bool
}

// MARK: - 候选构建（纯函数，可单测）

enum ProbeCandidateBuilder {
    /// 按用户优先级顺序构建候选链路列表。
    ///
    /// 传输协议按地址类型自动选择：
    /// - **IP 地址**（内网 / 公网 v4 / 公网 v6）：**HTTP 优先**，HTTPS 兜底。
    ///   IP 直连多为自签名证书，HTTP 可避开 AVFoundation 栈的证书校验；
    ///   若 NAS 只开 HTTPS 端口，HTTP 失败后自动回退 HTTPS。
    /// - **中继 / 域名**：**仅 HTTPS**。
    ///
    /// 地址列表为空的分组不贡献候选；中继组恒有兜底地址（`fnId.5ddd.com`）。
    static func build(
        fnId: String,
        params: FnConnectionParams,
        order: [ProbeCandidateGroup]
    ) -> [ProbeCandidateSpec] {
        var specs: [ProbeCandidateSpec] = []
        let ipSchemes: [(String, Bool)] = [("http", false), ("https", true)]

        func appendIP(_ ip: String, _ group: ProbeCandidateGroup, bracket: Bool) {
            for (scheme, isHttps) in ipSchemes {
                let port = isHttps ? params.httpsPort : params.httpPort
                let host = bracket ? "[\(ip)]" : ip
                specs.append(
                    ProbeCandidateSpec(
                        address: "\(scheme)://\(host):\(port)",
                        description: "\(scheme.uppercased()) (\(ip):\(port))",
                        group: group,
                        ipLabel: ip
                    )
                )
            }
        }

        for group in order {
            switch group {
            case .internal:
                params.internalIPv4s.forEach { appendIP($0, group, bracket: false) }
            case .publicIPv6:
                params.publicIPv6s.forEach { appendIP($0, group, bracket: true) }
            case .publicIPv4:
                params.publicIPv4s.forEach { appendIP($0, group, bracket: false) }
            case .relay:
                let relays = params.relayAddresses.isEmpty
                    ? [fnId.hasSuffix(".5ddd.com") ? fnId : "\(fnId).5ddd.com"]
                    : params.relayAddresses
                for addr in relays {
                    // 去掉可能携带的端口（中继固定 443）
                    let domain = addr.replacingOccurrences(
                        of: ":\\d+$", with: "", options: .regularExpression
                    )
                    specs.append(
                        ProbeCandidateSpec(
                            address: "https://\(domain)",
                            description: "HTTPS (\(domain))",
                            group: group,
                            ipLabel: nil,
                            relayMode: true
                        )
                    )
                }
            }
        }
        return specs
    }
}

// MARK: - 探测判定（纯函数，可单测）

enum ProbeVerdict {
    /// 判定候选是否可用。
    ///
    /// - `authChecked == true`（已登录、探测携带 token）：候选必须通过鉴权
    ///   （HTTP < 400 且业务 `code == 0`）才算可用，避免选到「能连上但用不了」
    ///   的链路——典型场景：登录凭据绑定 FNID 中继，而候选里有 TCP 可达的
    ///   公网直连 IP，会因 token 不匹配返回 401/INVALID TOKEN。
    /// - `authChecked == false`（登录前仅测连通性）：拿到响应即视为可用。
    ///
    /// 例外：无论是否鉴权，**HTTP 候选若被服务器 302 强制跳转 HTTPS 一律判为
    /// 不可用**——跨 scheme 重定向会丢 Cookie，后续资源请求必然失败。
    static func isUsable(status: Int, location: String?, body: [String: Any]?, authChecked: Bool) -> (usable: Bool, reason: String?) {
        if status >= 300, status < 400, let location, !location.isEmpty,
           location.hasPrefix("https://") || location.hasPrefix("/") {
            // 仅当跳转目标为 HTTPS 时才认定是「HTTP 强制跳转 HTTPS」
            if location.hasPrefix("https://") {
                return (false, "服务器强制跳转 HTTPS，HTTP 端口不可直连")
            }
        }
        if !authChecked { return (true, nil) }
        if status >= 400 {
            return (false, "HTTP \(status)")
        }
        if let code = body?["code"] as? Int, code != 0 {
            return (false, "业务码 \(code)")
        }
        if let msg = body?["msg"] as? String, msg.lowercased().contains("invalid token") {
            return (false, "INVALID TOKEN")
        }
        return (true, nil)
    }

    /// 探测超时：中继链路最长（设备 → 5ddd.com CDN → FN 设备转发），放宽到 10s；
    /// 直连 IP 3s。
    static func timeout(isRelay: Bool) -> TimeInterval {
        isRelay ? 10 : 3
    }
}
