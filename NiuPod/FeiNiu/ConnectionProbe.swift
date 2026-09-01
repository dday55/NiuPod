import Foundation

/// 飞牛连接探测：把 FNID 换成一组候选链路，然后用「缓存优先 + 并行早停」策略
/// 挑出当前最优的一条。
///
/// 设计要点（对齐 Android 端 FeiNiuMusic 的实现）：
/// 1. **缓存优先**：先快探上次成功的地址，仍可用就只探测优先级更高的候选，
///    扫得到就升级，扫不到就保持——绝不降级，避免频繁抖动。
/// 2. **并行早停**：所有候选同时发起，但严格按优先级取「第一个已确认可达且
///    不存在更高优先级未决项」的链路，既不牺牲优先级，也不慢于全量等待。
/// 3. **鉴权校验**：已登录时探测携带 `music-token`，候选必须通过鉴权才算可用，
///    避免选到「能连上但用不了」的链路（凭据绑定中继时公网 IP 会 401）。
actor ConnectionProbe {

    private let session: URLSession

    init(session: URLSession = .niupod) {
        self.session = session
    }

    // MARK: - 单条候选探测

    /// 探测单条候选链路
    private func probe(
        _ spec: ProbeCandidateSpec,
        token: String?,
        accessCode: String?
    ) async -> ProbeCandidateResult {
        let started = Date()
        let authChecked = token != nil && !(token?.isEmpty ?? true)
        // 已登录打一个轻量鉴权接口验证 token 是否被该地址接受；未登录只探根路径（TCP 可达性）
        let probePath = authChecked ? "/music/api/v1/track/list" : ""
        guard let url = URL(string: spec.address + probePath) else {
            return ProbeCandidateResult(spec: spec, isReachable: false, error: "地址非法")
        }

        var request = URLRequest(url: url, timeoutInterval: ProbeVerdict.timeout(isRelay: spec.relayMode))
        request.httpMethod = "GET"
        // 注意：中继与鉴权要合并进同一个 Cookie 头，拆成两个会互相覆盖，
        // 导致中继链路丢掉 mode=relay 被服务器误判。
        var cookieParts: [String] = []
        if let token, !token.isEmpty { cookieParts.append("music-token=\(token)") }
        if spec.relayMode { cookieParts.append("mode=relay") }
        if !cookieParts.isEmpty {
            request.setValue(cookieParts.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        if let code = accessCode, !code.isEmpty {
            request.setValue(Data(code.utf8).base64EncodedString(), forHTTPHeaderField: "x-access-code")
            request.setValue("app", forHTTPHeaderField: "x-access-source")
        }

        let elapsed: () -> Int = { Int(Date().timeIntervalSince(started) * 1000) }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return ProbeCandidateResult(spec: spec, isReachable: false, error: "无响应", elapsedMs: elapsed())
            }
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { acc, pair in
                if let k = pair.key as? String, let v = pair.value as? String { acc[k.lowercased()] = v }
            }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let verdict = ProbeVerdict.isUsable(
                status: http.statusCode,
                location: headers["location"],
                body: body,
                authChecked: authChecked
            )
            Log.net("[FnProbe] \(verdict.usable ? "✓" : "✗") \(spec.description) \(http.statusCode) \(elapsed())ms")
            return ProbeCandidateResult(
                spec: spec,
                isReachable: verdict.usable,
                error: verdict.reason,
                elapsedMs: elapsed()
            )
        } catch {
            if (error as? URLError)?.code == .cancelled {
                return ProbeCandidateResult(spec: spec, isReachable: false, error: "已取消", elapsedMs: elapsed())
            }
            Log.net("[FnProbe] ✗ \(spec.description) \(error.localizedDescription)")
            return ProbeCandidateResult(
                spec: spec,
                isReachable: false,
                error: error.localizedDescription,
                elapsedMs: elapsed()
            )
        }
    }

    // MARK: - 并行早停

    /// 结果元组：优先级最高且已确认可达者 + 返回时已得出结论的候选列表
    struct BestResult: Sendable {
        let best: ProbeCandidateResult?
        let bestIndex: Int?
        let decided: [ProbeCandidateResult]
    }

    /// 并发探测所有候选，按优先级取「首个已确认可达」的链路，支持早停。
    ///
    /// 不变量：
    /// 1. 不牺牲优先级：仍有更高优先级候选未出结果时绝不返回。
    /// 2. 不慢于全量等待：返回时刻 ≤ 所有候选探测完成时刻。
    private func probeBestReachable(
        _ candidates: [ProbeCandidateSpec],
        token: String?,
        accessCode: String?
    ) async -> BestResult {
        if candidates.isEmpty {
            return BestResult(best: nil, bestIndex: nil, decided: [])
        }

        return await withTaskGroup(of: (Int, ProbeCandidateResult).self) { group in
            for (index, spec) in candidates.enumerated() {
                group.addTask {
                    let r = await self.probe(spec, token: token, accessCode: accessCode)
                    return (index, r)
                }
            }

            var pending = Set(candidates.indices)
            var best: ProbeCandidateResult?
            var bestIndex: Int?
            var decided: [ProbeCandidateResult] = []

            while !pending.isEmpty {
                guard let (idx, result) = await group.next() else { break }
                pending.remove(idx)
                decided.append(result)

                if result.isReachable, bestIndex == nil || idx < bestIndex! {
                    bestIndex = idx
                    best = result
                }

                // 早停：已有可达者，且不存在仍未决定的更高优先级候选
                if let bi = bestIndex, bi == 0 || !pending.contains(where: { $0 < bi }) {
                    group.cancelAll()
                    return BestResult(best: best, bestIndex: bestIndex, decided: decided)
                }
            }
            return BestResult(best: best, bestIndex: bestIndex, decided: decided)
        }
    }

    // MARK: - 对外入口

    /// 缓存优先探测（仅升级，不降级）
    ///
    /// - Parameters:
    ///   - fnId: FNID
    ///   - token: 已登录时的 `music-token`（nil 表示登录前纯连通性探测）
    ///   - cached: 上次成功的连接地址（来自 UserDefaults）
    ///   - cachedIsRelay: 上次连接是否为中继
    ///   - order: 分组优先级顺序
    func probeSmart(
        fnId: String,
        token: String?,
        accessCode: String? = nil,
        cached: (url: String, isRelay: Bool)? = nil,
        order: [ProbeCandidateGroup] = kDefaultConnectionOrder
    ) async throws -> ConnectionProbeResult {
        let params = try await FnConnectAPI.fetchConnectionParams(fnId: fnId, session: session)
        let candidates = ProbeCandidateBuilder.build(fnId: fnId, params: params, order: order)
        if candidates.isEmpty {
            throw FeiNiuError.allCandidatesFailed([])
        }

        // Step 1: 缓存优先快探
        if let cached, !cached.url.isEmpty,
           let cachedIndex = candidates.firstIndex(where: { $0.address == cached.url }) {
            let cachedSpec = candidates[cachedIndex]
            let cachedResult = await probe(cachedSpec, token: token, accessCode: accessCode)
            if cachedResult.isReachable {
                // 只探测优先级更高的候选，有就升级
                let better = Array(candidates[0..<cachedIndex])
                if !better.isEmpty {
                    let upgraded = await probeBestReachable(better, token: token, accessCode: accessCode)
                    if let b = upgraded.best {
                        Log.net("[FnProbe] 升级连接 → \(b.description)")
                        return ConnectionProbeResult(
                            serverUrl: b.address, probeMethod: b.description, isRelay: b.isRelay
                        )
                    }
                }
                Log.net("[FnProbe] 缓存连接仍有效 → \(cached.url)")
                return ConnectionProbeResult(
                    serverUrl: cached.url, probeMethod: "缓存连接", isRelay: cached.isRelay
                )
            }
            // 缓存不可达 → 回退全量探测
        }

        // Step 2: 全量探测
        let result = await probeBestReachable(candidates, token: token, accessCode: accessCode)
        guard let best = result.best else {
            throw FeiNiuError.allCandidatesFailed(result.decided)
        }
        Log.net("[FnProbe] 全量探测成功 → \(best.address)")
        return ConnectionProbeResult(
            serverUrl: best.address, probeMethod: best.description, isRelay: best.isRelay
        )
    }

    /// 探测所有候选链路（用于设置页「连接诊断」完整展示每条链路状态）
    func probeAll(
        fnId: String,
        token: String?,
        accessCode: String? = nil,
        order: [ProbeCandidateGroup] = kDefaultConnectionOrder
    ) async throws -> (candidates: [ProbeCandidateResult], firstSuccess: ConnectionProbeResult?) {
        let params = try await FnConnectAPI.fetchConnectionParams(fnId: fnId, session: session)
        let specs = ProbeCandidateBuilder.build(fnId: fnId, params: params, order: order)

        let results = await withTaskGroup(of: ProbeCandidateResult.self) { group in
            for spec in specs {
                group.addTask { await self.probe(spec, token: token, accessCode: accessCode) }
            }
            var out: [ProbeCandidateResult] = []
            for await r in group { out.append(r) }
            // 按候选顺序还原（便于分组展示）
            return specs.compactMap { spec in out.first { $0.address == spec.address } }
        }

        let first = results.first(where: \.isReachable).map {
            ConnectionProbeResult(serverUrl: $0.address, probeMethod: $0.description, isRelay: $0.isRelay)
        }
        return (results, first)
    }

    /// 快速校验单个地址是否仍可达（回到前台时的一次性轻量检查，不触发完整探测）
    func isReachable(url: String, isRelay: Bool, token: String?, accessCode: String? = nil) async -> Bool {
        let spec = ProbeCandidateSpec(
            address: url, description: url, group: isRelay ? .relay : .internal,
            ipLabel: nil, relayMode: isRelay
        )
        let r = await probe(spec, token: token, accessCode: accessCode)
        return r.isReachable
    }
}
