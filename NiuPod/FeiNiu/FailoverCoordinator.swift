import Foundation

/// 运行时链路自动切换
///
/// API 请求网络超时 / 断连时，重新探测全部候选链路；若发现更优/可用的链路
/// （例如当前公网 IP 超时 → 内网 IP 或中继），就切换凭据并让调用方重试。
/// 只支持 FNID 登录（有候选链路）；手动填地址没有候选，无法切换。
actor FailoverCoordinator {
    static let shared = FailoverCoordinator()

    /// 切换成功后通知外层（Session）更新凭据并持久化。
    /// 第二个参数是新链路的描述（如「内网 (192.168.1.2:5666)」），用于刷新设置页状态。
    var onCredentialsChanged: (@Sendable (Credentials, String) -> Void)?

    /// 同一链路 10 秒内只自动切换一次，避免多个并发请求同时触发全量探测
    private var lastSwitch: (key: String, date: Date)?

    /// 注册切换成功后的回调（App 启动时调用一次）
    func register(_ handler: (@Sendable (Credentials, String) -> Void)?) {
        onCredentialsChanged = handler
    }

    /// 探测并切换到可用链路；无候选 / 探测失败 / 当前链路仍是最优时返回 nil。
    func switchCredentials(current: Credentials) async -> Credentials? {
        guard !current.fnId.isEmpty else { return nil }  // 手动地址没有候选链路
        let key = "\(current.baseUrl)|\(current.token)"
        if let last = lastSwitch, last.key == key, Date().timeIntervalSince(last.date) < 10 {
            return nil
        }
        lastSwitch = (key, Date())

        do {
            let probe = ConnectionProbe()
            let result = try await probe.probeSmart(
                fnId: current.fnId,
                token: current.token,
                accessCode: current.accessCode,
                cached: (current.baseUrl, current.relayMode),
                order: CredentialsStore.connectionOrder
            )
            let newBase = Credentials.normalizeBaseUrl(result.serverUrl)
            guard newBase != Credentials.normalizeBaseUrl(current.baseUrl) else {
                Log.net("[Failover] 探测后仍是当前链路，无需切换")
                return nil
            }
            var new = current
            new.baseUrl = newBase
            new.relayMode = result.isRelay
            Log.net("[Failover] 自动切换 → \(result.serverUrl) (\(result.probeMethod))")
            onCredentialsChanged?(new, result.probeMethod)
            return new
        } catch {
            Log.error("[Failover] 自动切换探测失败：\(error.localizedDescription)")
            return nil
        }
    }
}
