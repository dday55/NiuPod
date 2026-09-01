import Foundation

/// 飞牛连接与登录状态（UI 唯一的状态源）
@MainActor
@Observable
final class Session {
    var credentials: Credentials
    var isLoggedIn: Bool
    var isWorking = false
    /// 面向用户的进度/错误文案
    var message: String?
    var lastProbeMethod: String?
    /// 服务器要求安全码但当前为空 → UI 弹出安全码输入
    var needsAccessCode = false
    /// 登录失效需要用户重新输密码（静默重登失败时）
    var requiresReauth = false
    /// 演示模式：用本地占位数据浏览界面，不连服务器、不播放
    var isDemo = false

    private let probe = ConnectionProbe()
    private var autoReloginTask: Task<Void, Never>?
    /// 重连失败后的自动重试任务：网络恢复后无需手动点「立即重连」
    private var reconnectRetryTask: Task<Void, Never>?
    /// 连续失败次数（用于退避）
    private var retryAttempt = 0
    /// 自适应退避：先快后慢，避免固定间隔傻轮询
    private static let retryDelays: [TimeInterval] = [3, 6, 12, 30, 60]

    init() {
        let c = CredentialsStore.load()
        credentials = c
        isLoggedIn = c.isValid
        if c.deviceId.isEmpty {
            credentials.deviceId = FeiNiuClient.generateDeviceId()
        }
    }

    var client: FeiNiuClient { FeiNiuClient(credentials: credentials) }

    var deviceId: String {
        if credentials.deviceId.isEmpty {
            credentials.deviceId = FeiNiuClient.generateDeviceId()
        }
        return credentials.deviceId
    }

    // MARK: - 登录

    /// 登录入口。
    ///
    /// - Parameters:
    ///   - fnId: FNID（留空则用手动地址）
    ///   - manualAddress: 手动填写的服务器地址，如 `http://192.168.1.2:5666`
    ///   - username / password: 飞牛账号
    ///   - accessCode: 安全码（服务器开启访问码防护时必填）
    func login(
        fnId: String?,
        manualAddress: String?,
        username: String,
        password: String
    ) async {
        guard !isWorking else { return }
        isWorking = true
        message = "正在连接…"
        defer { isWorking = false }

        do {
            // Step 1 —— 确定服务器基址
            var baseUrl: String
            var isRelay = false

            if let fnId, !fnId.trimmed.isEmpty {
                let id = fnId.trimmed
                message = "正在解析 FNID…"
                let cached: (String, Bool)? = credentials.fnId == id && isLoggedIn
                    ? (credentials.baseUrl, credentials.relayMode)
                    : nil
                let result = try await probe.probeSmart(
                    fnId: id,
                    token: isLoggedIn ? credentials.token : nil,
                    accessCode: credentials.accessCode,
                    cached: cached,
                    order: CredentialsStore.connectionOrder
                )
                baseUrl = result.serverUrl
                isRelay = result.isRelay
                credentials.fnId = id
                lastProbeMethod = result.probeMethod
                message = "已选择链路：\(result.probeMethod)"
            } else if let manualAddress, !manualAddress.trimmed.isEmpty {
                message = "正在探测地址…"
                let (resolved, relay) = try await Self.probeManualAddress(
                    manualAddress.trimmed, accessCode: credentials.accessCode
                )
                baseUrl = resolved
                isRelay = relay
                credentials.fnId = ""
                lastProbeMethod = resolved
            } else {
                throw FeiNiuError.server(code: -1, msg: "请填写 FNID 或服务器地址")
            }

            credentials.baseUrl = Credentials.normalizeBaseUrl(baseUrl)
            credentials.relayMode = isRelay

            // Step 2 —— 安全码握手（204 不需要 / 401 需要）
            if isRelay || baseUrl.contains("5ddd.com") {
                // 中继链路同样可能要求安全码，走统一流程
            }
            if await client.requiresAccessCode() {
                guard let code = credentials.accessCode, !code.isEmpty,
                      await client.verifyAccessCode(code) else {
                    needsAccessCode = true
                    message = "该服务器已开启安全码，请输入安全码"
                    return
                }
            }
            needsAccessCode = false

            // Step 3 —— 密码登录
            message = "正在登录…"
            let result = try await client.login(
                username: username.trimmed,
                password: password,
                deviceId: deviceId
            )

            credentials.token = result.userToken
            credentials.username = result.username ?? username.trimmed
            isLoggedIn = true
            requiresReauth = false
            message = nil
            CredentialsStore.save(credentials, password: password)
            Log.info("[Session] 登录成功：\(credentials.username) @ \(credentials.baseUrl)")
        } catch {
            message = error.localizedDescription
            Log.error("[Session] 登录失败：\(error.localizedDescription)")
        }
    }

    /// 提交安全码并继续登录
    func submitAccessCode(_ code: String, username: String, password: String) async {
        credentials.accessCode = code
        needsAccessCode = false
        let fnId = credentials.fnId.isEmpty ? nil : credentials.fnId
        await login(fnId: fnId, manualAddress: fnId == nil ? credentials.baseUrl : nil,
                    username: username, password: password)
    }

    // MARK: - 重连 / 恢复

    /// 冷启动恢复：凭据存在即认为已登录，随后后台校验链路
    func restoreAndVerifyIfPossible() async {
        guard isLoggedIn else { return }
        let ok = await client.ping()
        if !ok {
            Log.info("[Session] 启动时校验失败，尝试重连")
            await reconnect()
        }
    }

    /// 回到前台 / 网络恢复时的重连。
    ///
    /// 有 FNID 时**总是**走「缓存优先 + 只升级」探测：即使当前链路（如中继）
    /// 还能通，也会检查更高优先级的内网候选——否则外网切到内网后永远留在中继。
    /// 手动 / 前台 / 网络路径变化触发的重连（非重试任务）
    func reconnect() async {
        await reconnect(fromRetry: false)
    }

    private func reconnect(fromRetry: Bool) async {
        guard isLoggedIn, !isWorking else { return }
        if !fromRetry {
            // 手动/事件触发的重连：取消挂起的定时重试并重置退避
            reconnectRetryTask?.cancel()
            reconnectRetryTask = nil
            retryAttempt = 0
        }
        isWorking = true
        defer {
            isWorking = false
            if message == nil || message?.isEmpty == true {
                // 成功：取消自动重试并重置退避
                retryAttempt = 0
                reconnectRetryTask?.cancel()
                reconnectRetryTask = nil
            } else {
                // 失败：按退避间隔自动再试，直到恢复
                scheduleReconnectRetry()
            }
        }

        if !credentials.fnId.isEmpty {
            let oldBase = credentials.baseUrl
            do {
                let result = try await probe.probeSmart(
                    fnId: credentials.fnId,
                    token: credentials.token,
                    accessCode: credentials.accessCode,
                    cached: (credentials.baseUrl, credentials.relayMode),
                    order: CredentialsStore.connectionOrder
                )
                credentials.baseUrl = Credentials.normalizeBaseUrl(result.serverUrl)
                credentials.relayMode = result.isRelay
                // 链路真的变了才更新描述（未升级时 probeMethod 是「缓存连接」，
                // 不能覆盖原有“内网 (192.168…)”这类描述）
                if credentials.baseUrl != oldBase {
                    lastProbeMethod = result.probeMethod
                    Log.net("[Session] 重连升级 → \(result.serverUrl) (\(result.probeMethod))")
                }
                CredentialsStore.save(credentials)
                if await client.ping() {
                    message = nil
                    return
                }
            } catch {
                Log.error("[Session] 重连探测失败：\(error.localizedDescription)")
                // 网络/SSL/超时等不可达问题 ≠ token 失效：直接提示网络，
                // 不要误报「登录已失效」；只有非网络类失败才继续走静默重登
                if FeiNiuClient.isFailoverableNetworkError(error) {
                    message = "网络不可达，请检查网络后重试"
                    return
                }
            }
        } else if await client.ping() {
            // 手动地址没有候选链路，只能确认当前地址仍可用
            message = nil
            return
        }

        // 链路没问题但 token 失效 → 静默重登
        await silentRelogin()
    }

    /// 重连失败后自动重试：按 3s/6s/12s/30s/60s 自适应退避，
    /// 成功后状态自动清空；网络路径变化时由 NWPathMonitor 立即触发，不等定时器。
    private func scheduleReconnectRetry() {
        guard isLoggedIn, !isWorking, reconnectRetryTask == nil else { return }
        let index = min(retryAttempt, Self.retryDelays.count - 1)
        let delay = Self.retryDelays[index]
        retryAttempt += 1
        reconnectRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.reconnectRetryTask = nil
            await self.reconnect(fromRetry: true)
        }
    }

    /// 静默重登（用 Keychain 里保存的密码）
    private func silentRelogin() async {
        guard let password = CredentialsStore.loadPassword(), !password.isEmpty else {
            requiresReauth = true
            return
        }
        let username = credentials.username
        let before = credentials.token
        do {
            let result = try await client.login(
                username: username, password: password, deviceId: deviceId
            )
            credentials.token = result.userToken
            isLoggedIn = true
            requiresReauth = false
            message = nil
            CredentialsStore.save(credentials)
            Log.info("[Session] 静默重登成功")
            if before != result.userToken {
                Log.info("[Session] token 已刷新")
            }
        } catch {
            if FeiNiuClient.isFailoverableNetworkError(error) {
                // 网络/SSL/超时问题不是 token 失效，别让用户以为要重新登录
                message = "网络异常，暂时无法自动重登"
                return
            }
            requiresReauth = true
            message = "登录已失效，请重新登录"
        }
    }

    /// API 层抛出 401 / INVALID TOKEN 时调用
    func handleUnauthorized() {
        guard !requiresReauth else { return }
        autoReloginTask?.cancel()
        autoReloginTask = Task { [weak self] in
            await self?.silentRelogin()
        }
    }

    // MARK: - 演示模式

    /// 进入演示模式：用本地占位数据浏览界面，不连服务器也不播放
    func enterDemo() {
        reconnectRetryTask?.cancel()
        reconnectRetryTask = nil
        isDemo = true
        isLoggedIn = false
        requiresReauth = false
        needsAccessCode = false
        message = nil
        Log.info("[Session] 进入演示模式")
    }

    func exitDemo() {
        isDemo = false
        message = nil
    }

    // MARK: - 登出

    func logout() {
        reconnectRetryTask?.cancel()
        reconnectRetryTask = nil
        CredentialsStore.clearSession()
        credentials.token = ""
        credentials.accessCode = nil
        credentials.relayMode = false
        isLoggedIn = false
        requiresReauth = false
        needsAccessCode = false
        message = nil
        lastProbeMethod = nil
    }

    /// 探测 FNID 下的所有链路（设置页「连接诊断」用）
    func diagnoseAllCandidates() async throws -> ([ProbeCandidateResult], ConnectionProbeResult?) {
        try await probe.probeAll(
            fnId: credentials.fnId,
            token: credentials.token,
            accessCode: credentials.accessCode,
            order: CredentialsStore.connectionOrder
        )
    }

    // MARK: - 手动地址探测

    /// 探测用户手填的地址，处理「HTTP 强制跳转 HTTPS」。
    ///
    /// 用户填 `http://ip:5666` 而服务器开了强制跳转时，HTTP 端口会 302 到
    /// `https://ip:5667`。跨 scheme 重定向会丢 Cookie，必须直接改用 HTTPS 登录。
    ///
    /// - Returns: (最终可用的基址, 是否中继)
    static func probeManualAddress(_ raw: String, accessCode: String?) async throws -> (String, Bool) {
        guard let url = URL(string: raw + "/music/api/v1/track/list") else {
            throw FeiNiuError.invalidURL(raw)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        if let code = accessCode, !code.isEmpty {
            request.setValue(Data(code.utf8).base64EncodedString(), forHTTPHeaderField: "x-access-code")
            request.setValue("app", forHTTPHeaderField: "x-access-source")
        }
        guard let (_, response) = try? await URLSession.niupod.data(for: request),
              let http = response as? HTTPURLResponse else {
            throw FeiNiuError.network(underlying: URLError(.cannotConnectToHost))
        }
        if let location = http.value(forHTTPHeaderField: "location"),
           location.hasPrefix("https://"),
           let target = URL(string: location) {
            // 剥掉 /music/api/v1/... 路径，恢复纯基址
            var base = "\(target.scheme ?? "https")://\(target.host ?? "" )"
            if let port = target.port { base += ":\(port)" }
            return (base, false)
        }
        if (200..<400).contains(http.statusCode) || http.statusCode == 401 {
            return (Credentials.normalizeBaseUrl(raw), false)
        }
        throw FeiNiuError.httpStatus(http.statusCode, "地址不可达")
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
