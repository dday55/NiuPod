import AVFoundation
import MediaPlayer
import UIKit

enum RepeatMode: String, CaseIterable, Identifiable {
    case off, all, one
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "关闭"
        case .all: "列表循环"
        case .one: "单曲循环"
        }
    }
    var symbolName: String {
        switch self {
        case .off: "repeat"
        case .all: "repeat"
        case .one: "repeat.1"
        }
    }
}

/// 加载阶段探测结论
private enum StreamVerdict {
    case playable
    case skipped
    case unauthorized
    case networkIssue
}

/// 播放引擎
///
/// 三件事值得说明：
/// 1. **认证流**：直接用真实 HTTP(S) 地址播放，并通过 `AVURLAssetHTTPHeaderFieldsKey`
///    注入 Cookie / 安全码；加载前先探测流是否可播，不支持的地址直接过滤。
/// 2. **失效歌曲**：`accessStatus == 3`（文件已删除）或格式不受支持（APE/WMA/OGG…）
///    的曲目自动跳过，避免播到一半报错。
/// 3. **锁屏控制**：注册 `RemoteCommandCenter` 并写入 `MPNowPlayingInfoCenter`，
///    系统控制中心 / 耳机 / CarPlay 都能控制。
@MainActor
@Observable
final class AudioPlayer {

    // MARK: 对外状态
    private(set) var queue: [Track] = []
    private(set) var index: Int = 0
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var currentLyrics: [LyricLine] = []
    private(set) var currentLyricIndex: Int = -1
    var errorMessage: String?

    var shuffle = false
    var repeatMode: RepeatMode = .all

    var currentTrack: Track? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    /// 提供当前凭据（由外部注入，登录/重连后自动生效）
    var credentialsProvider: (() -> Credentials)?

    /// 播放失败且疑似会话失效时回调（用于触发静默重登）
    var onUnauthorized: (() -> Void)?

    /// 演示模式：不取流，仅推进时间轴
    var isDemo = false

    // MARK: 内部
    private var player = AVPlayer()
    private var timeObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var shuffleOrder: [Int] = []
    private var currentAsset: AVURLAsset?
    /// AVURLAsset 注入自定义 HTTP 头的私有 key（被 Apple 广泛使用的未文档化方案）
    private static let httpHeaderFieldsKey = "AVURLAssetHTTPHeaderFieldsKey"
    /// 加载阶段探测结果缓存（baseUrl|token|guid → 是否可播），避免每首歌反复探测
    private var preflightCache: [String: Bool] = [:]
    private var lyricsTask: Task<Void, Never>?
    private var demoTimer: Timer?
    /// 连续跳过失效歌曲的计数，用于防止队列全失效时无限递归
    private var consecutiveSkips = 0
    private static let maxConsecutiveSkips = 30
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    init() {
        configureAudioSession()
        setupRemoteCommands()
        observeAudioSessionEvents()
    }

    /// 音频会话：播放类别 + 激活。
    /// 真机上会话可能被电话/其他 App 打断或停用，所以每次播放前都要重新激活。
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            Log.error("[Player] 音频会话配置失败：\(error.localizedDescription)")
        }
    }

    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Log.error("[Player] 激活音频会话失败：\(error.localizedDescription)")
        }
    }

    private func observeAudioSessionEvents() {
        // 电话 / Siri 等打断：暂停；打断结束可恢复时自动续播
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
        // 拔掉耳机等输出设备消失：暂停，避免「看似在播但没声音」
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleRouteChange(note) }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            player.pause()
            isPlaying = false
            syncDemoTimer()
            updateNowPlayingPlaybackInfo()
        case .ended:
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                activateAudioSession()
                play()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        if reason == .oldDeviceUnavailable {
            player.pause()
            isPlaying = false
            syncDemoTimer()
            updateNowPlayingPlaybackInfo()
        }
    }

    // MARK: - 队列控制

    func playQueue(_ tracks: [Track], startingAt: Int = 0) {
        guard !tracks.isEmpty else { return }
        consecutiveSkips = 0
        queue = tracks
        index = max(0, min(startingAt, tracks.count - 1))
        rebuildShuffleOrder()
        loadCurrent(autoPlay: true)
    }

    func enqueue(_ tracks: [Track], next: Bool = false) {
        guard !tracks.isEmpty else { return }
        if next, queue.indices.contains(index) {
            queue.insert(contentsOf: tracks, at: index + 1)
        } else {
            queue.append(contentsOf: tracks)
        }
        rebuildShuffleOrder()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard currentTrack != nil else { return }
        if isDemo {
            // 播完停在末尾再按播放 → 从头开始
            if currentTime >= duration, duration > 0 { seek(to: 0) }
        } else {
            // 真机：会话可能被系统停用，播放前必须重新激活，否则会「看似在播但没声音」
            activateAudioSession()
            player.volume = 1
            player.isMuted = false
            player.play()
        }
        isPlaying = true
        syncDemoTimer()
        updateNowPlayingPlaybackInfo()
    }

    func pause() {
        player.pause()
        isPlaying = false
        syncDemoTimer()
        updateNowPlayingPlaybackInfo()
    }

    func stop() {
        consecutiveSkips = 0
        demoTimer?.invalidate()
        demoTimer = nil
        player.pause()
        isPlaying = false
        queue = []
        index = 0
        currentTime = 0
        duration = 0
        currentLyrics = []
        currentLyricIndex = -1
        player.replaceCurrentItem(with: nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func next(userInitiated: Bool = true) {
        goto(step: 1, userInitiated: userInitiated)
    }

    func previous() {
        // 播放超过 3 秒时，「上一首」先回到本曲开头（与主流播放器一致）
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        goto(step: -1, userInitiated: true)
    }

    private func goto(step: Int, userInitiated: Bool) {
        guard !queue.isEmpty else { return }
        if !userInitiated, repeatMode == .one {
            seek(to: 0)
            play()
            return
        }
        var nextIndex: Int
        if shuffle, !shuffleOrder.isEmpty {
            if let pos = shuffleOrder.firstIndex(of: index) {
                let p = (pos + step + shuffleOrder.count) % shuffleOrder.count
                nextIndex = shuffleOrder[p]
            } else {
                nextIndex = (index + step + queue.count) % queue.count
            }
        } else {
            nextIndex = index + step
            if nextIndex >= queue.count {
                nextIndex = repeatMode == .off && userInitiated ? queue.count - 1 : 0
            } else if nextIndex < 0 {
                nextIndex = repeatMode == .off && userInitiated ? 0 : queue.count - 1
            }
        }
        guard queue.indices.contains(nextIndex) else { return }

        // 自动播放到队尾且关闭循环 → 停在当前曲目末尾
        if !userInitiated, repeatMode == .off, step > 0, nextIndex <= index {
            pause()
            seek(to: 0)
            return
        }
        index = nextIndex
        loadCurrent(autoPlay: true)
    }

    func seek(to time: Double) {
        let clamped = max(0, min(time, duration > 0 ? duration : time))
        if isDemo {
            // 演示模式没有真实音频，直接推进时间轴让进度条与歌词动起来
            currentTime = clamped
            syncLyricIndex()
            updateNowPlayingPlaybackInfo()
            return
        }
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.currentTime = clamped
                self?.updateNowPlayingPlaybackInfo()
                self?.syncLyricIndex()
            }
        }
    }

    func seek(by delta: Double) {
        seek(to: currentTime + delta)
    }

    private func rebuildShuffleOrder() {
        shuffleOrder = queue.indices.shuffled()
    }

    /// 切换随机播放。
    ///
    /// 关闭时可以把乱序队列还原成原始顺序（`orderedQueue`），并保持当前曲目
    /// 不变——否则用户关掉随机后队列仍是乱的，等于没关。
    func setShuffle(_ enabled: Bool, orderedQueue: [Track]? = nil) {
        guard enabled != shuffle else { return }
        let current = currentTrack
        shuffle = enabled
        if let ordered = orderedQueue, !ordered.isEmpty {
            queue = ordered
            index = current.flatMap { ordered.firstIndex(of: $0) } ?? max(0, min(index, ordered.count - 1))
        }
        rebuildShuffleOrder()
    }

    // MARK: - 装载当前曲目

    private func loadCurrent(autoPlay: Bool) {
        if isDemo { loadDemoCurrent(autoPlay: autoPlay); return }

        guard let track = currentTrack,
              let creds = credentialsProvider?(), creds.isValid,
              let realURL = FeiNiuClient(credentials: creds).streamURL(guid: track.guid) else {
            errorMessage = "无法获取音频地址"
            return
        }

        // 失效歌曲（音频文件已删除）或格式不受支持（APE/WMA/OGG…）：
        // AVPlayer 播不了，直接跳过。必须限制连续跳过次数——队列里全是这类歌曲时
        // 会一首接一首地递归跳下去，每 0.3 秒一次，永远停不下来。
        if track.isAudioFileDeleted || track.isFormatUnsupported {
            let message = track.isAudioFileDeleted
                ? "《\(track.title)》音频文件已失效，已跳过"
                : "《\(track.title)》格式不受支持，已跳过"
            skipCurrentTrack(track: track, message: message)
            return
        }

        consecutiveSkips = 0
        isLoading = true
        errorMessage = nil
        currentTime = 0
        duration = track.durationSeconds

        let headers = FeiNiuClient(credentials: creds).resourceHeaders

        // 加载阶段过滤：先探测真实流地址是否可被 AVPlayer 原生播放
        // （必须是 http/https、服务端确实返回音频内容）。不可播的曲目
        // 在进入 AVPlayer 之前就跳过，不再出现「不支持的 URL」(-1002)。
        Task { @MainActor in
            let verdict = await self.preflightStream(
                realURL: realURL, headers: headers, creds: creds, track: track
            )
            guard self.currentTrack?.guid == track.guid else { return }
            switch verdict {
            case .playable, .networkIssue:
                // networkIssue 不判死：网络抖动时让 AVPlayer 自己重试/报错
                self.prepareItem(track: track, realURL: realURL, headers: headers, autoPlay: autoPlay)
                self.loadLyrics(for: track)
                self.updateNowPlayingMetadata()
                self.reportPlayback(of: track)
            case .skipped:
                break   // skipCurrentTrack 已调度下一首
            case .unauthorized:
                self.isLoading = false
                self.errorMessage = "登录已失效，请重新登录"
                self.onUnauthorized?()
            }
        }
    }

    /// 加载阶段探测音频流是否可播（带每曲缓存）。
    private func preflightStream(
        realURL: URL, headers: [String: String], creds: Credentials, track: Track
    ) async -> StreamVerdict {
        // 只放行 AVPlayer 原生支持的 http/https；其它 scheme 直接过滤
        guard let scheme = realURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            skipCurrentTrack(track: track, message: "《\(track.title)》音频地址不受支持，已跳过")
            return .skipped
        }
        let cacheKey = "\(creds.baseUrl)|\(creds.token)|\(track.guid)"
        if let cached = preflightCache[cacheKey] {
            if cached { return .playable }
            skipCurrentTrack(track: track, message: "《\(track.title)》音频地址不受支持，已跳过")
            return .skipped
        }
        switch await StreamProbe.probe(url: realURL, headers: headers) {
        case .ok:
            preflightCache[cacheKey] = true
            return .playable
        case .unsupported:
            preflightCache[cacheKey] = false
            skipCurrentTrack(track: track, message: "《\(track.title)》音频地址不受支持，已跳过")
            return .skipped
        case .unauthorized:
            preflightCache[cacheKey] = false
            return .unauthorized
        case .network:
            // 当前链路疑似不通：自动切换到候选链路后用新地址重试一次
            if let newCreds = await FailoverCoordinator.shared.switchCredentials(current: creds) {
                let newClient = FeiNiuClient(credentials: newCreds)
                if let newURL = newClient.streamURL(guid: track.guid) {
                    return await preflightStream(
                        realURL: newURL,
                        headers: newClient.resourceHeaders,
                        creds: newCreds,
                        track: track
                    )
                }
            }
            return .networkIssue
        }
    }

    /// 跳过当前不可播放曲目（带连续跳过上限，防止队列全废时无限递归）。
    /// 调度跳转前会再次确认当前曲目没变，避免用户手动切歌后又被旧任务跳走。
    private func skipCurrentTrack(track: Track, message: String) {
        consecutiveSkips += 1
        let limit = max(1, min(queue.count, Self.maxConsecutiveSkips))
        guard consecutiveSkips <= limit else {
            isLoading = false
            isPlaying = false
            errorMessage = "队列里没有可播放的歌曲（\(consecutiveSkips) 首已跳过）"
            Log.error("[Player] 连续跳过 \(consecutiveSkips) 首不可播放歌曲，停止播放")
            return
        }
        errorMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.currentTrack?.guid == track.guid else { return }
            self.next(userInitiated: false)
        }
    }

    /// 创建并装载当前曲目的 AVPlayerItem：真实 HTTP(S) URL 直连，
    /// 注入认证头（Cookie / x-access-code），并禁用压缩。
    private func prepareItem(track: Track, realURL: URL, headers: [String: String], autoPlay: Bool) {
        // 音频流一旦被 gzip 包装，AVPlayer 会拿不到可解码的裸音频
        var streamHeaders = headers
        streamHeaders["Accept-Encoding"] = "identity"
        let asset = AVURLAsset(url: realURL, options: [
            Self.httpHeaderFieldsKey: streamHeaders
        ])
        currentAsset = asset
        let item = AVPlayerItem(asset: asset)

        // 先挂观察再替换当前项：避免 item 快速失败/就绪时错过状态回调
        observe(item, track: track)
        player.replaceCurrentItem(with: item)

        player.volume = 1
        player.isMuted = false

        if autoPlay { player.play(); isPlaying = true }
    }

    /// 上报播放历史（fire-and-forget，失败只记日志）
    private func reportPlayback(of track: Track) {
        guard let creds = credentialsProvider?(), creds.isValid else { return }
        Task.detached {
            let client = FeiNiuClient(credentials: creds)
            await client.reportPlay(trackGuid: track.guid)
        }
    }

    // MARK: - 演示模式

    /// 演示模式：不取流，只推进时间轴，让进度条与歌词动起来
    private func loadDemoCurrent(autoPlay: Bool) {
        guard let track = currentTrack else { return }
        consecutiveSkips = 0
        player.replaceCurrentItem(with: nil)
        isLoading = false
        errorMessage = nil
        currentTime = 0
        duration = track.durationSeconds
        currentLyrics = LRCParser.parse(DemoData.demoLyrics(for: track)).lines
        currentLyricIndex = -1
        isPlaying = autoPlay
        syncDemoTimer()
    }

    private func syncDemoTimer() {
        demoTimer?.invalidate()
        demoTimer = nil
        guard isDemo, isPlaying, duration > 0 else { return }
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isDemo, self.isPlaying else { return }
                self.currentTime += 0.25
                self.syncLyricIndex()
                self.updateNowPlayingPlaybackInfo()
                if self.currentTime >= self.duration {
                    self.goto(step: 1, userInitiated: false)
                }
            }
        }
    }

    private func observe(_ item: AVPlayerItem, track: Track) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(\.status) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.isLoading = false
                    let d = item.duration.seconds
                    if d.isFinite, d > 0 { self.duration = d }
                    self.updateNowPlayingMetadata()
                case .failed:
                    self.isLoading = false
                    let err = item.error
                    // 「不支持的 URL」(-1002)：播放器根本不认这个地址，按不可播放
                    // 曲目过滤，直接跳到下一首（加载阶段探测没拦住时的兜底）。
                    if let nsErr = err as NSError?, nsErr.code == -1002 {
                        self.skipCurrentTrack(track: track, message: "《\(track.title)》音频地址不受支持，已跳过")
                        return
                    }
                    self.errorMessage = err?.localizedDescription ?? "播放失败"
                    Log.error("[Player] 装载失败：\(String(describing: err))")
                    if let nsErr = err as NSError?,
                       nsErr.domain == AVFoundationErrorDomain || nsErr.code == -1102 {
                        // 401/403 之类的资源错误很可能是 token 失效
                        self.onUnauthorized?()
                    }
                default:
                    break
                }
            }
        }

        timeObserver.map { player.removeTimeObserver($0) }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.currentTime = time.seconds
                self.syncLyricIndex()
                self.updateNowPlayingPlaybackInfo()
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - self.duration) > 0.5 {
                    self.duration = d
                }
            }
        }

        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.goto(step: 1, userInitiated: false) }
        }
    }

    // MARK: - 歌词

    private func loadLyrics(for track: Track) {
        lyricsTask?.cancel()
        currentLyrics = []
        currentLyricIndex = -1
        guard track.hasLyric != false else { return }
        guard let creds = credentialsProvider?(), creds.isValid else { return }

        lyricsTask = Task { [weak self] in
            let client = FeiNiuClient(credentials: creds)
            guard let text = try? await client.lyricText(trackGUID: track.guid) else { return }
            let parsed = LRCParser.parse(text).lines
            await MainActor.run {
                guard let self, self.currentTrack?.guid == track.guid else { return }
                self.currentLyrics = parsed
                self.syncLyricIndex()
            }
        }
    }

    private func syncLyricIndex() {
        guard !currentLyrics.isEmpty else { currentLyricIndex = -1; return }
        currentLyricIndex = LRCParser.index(of: currentTime, in: currentLyrics)
    }

    // MARK: - 锁屏 / 控制中心

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: e.positionTime) }
            return .success
        }
    }

    private func baseNowPlayingInfo() -> [String: Any] {
        guard let track = currentTrack else { return [:] }
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistName,
            MPMediaItemPropertyAlbumTitle: track.album.name,
            MPMediaItemPropertyPlaybackDuration: duration.isFinite ? duration : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        return info
    }

    private func updateNowPlayingMetadata() {
        var info = baseNowPlayingInfo()
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        guard let track = currentTrack, let creds = credentialsProvider?(), creds.isValid else { return }
        Task { [weak self] in
            let image = await ArtworkLoader.image(
                for: track.coverId ?? track.album.coverId,
                using: FeiNiuClient(credentials: creds)
            )
            guard let self else { return }
            await MainActor.run {
                guard self.currentTrack?.guid == track.guid else { return }
                var updated = self.baseNowPlayingInfo()
                if let image {
                    updated[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                }
                updated[MPNowPlayingInfoPropertyElapsedPlaybackTime] = self.currentTime
                updated[MPNowPlayingInfoPropertyPlaybackRate] = self.isPlaying ? 1.0 : 0.0
                MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
            }
        }
    }

    private func updateNowPlayingPlaybackInfo() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? baseNowPlayingInfo()
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPMediaItemPropertyPlaybackDuration] = duration.isFinite ? duration : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
