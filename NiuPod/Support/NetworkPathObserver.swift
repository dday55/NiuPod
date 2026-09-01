import Foundation
import Network

/// 网络路径变化监听
///
/// Wi-Fi / 蜂窝 / 网线切换、网络断开重连时触发回调，让 Session 重新探测链路。
/// 这样从外网切到内网 Wi-Fi 时，会自动重新探测并优先升级到内网直连
/// （探测策略本来就是「只升级不降级」：内网可用就切内网，不可用保持现状）。
final class NetworkPathObserver {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "niupod.netpath")
    private var lastKey: String?
    private var lastTriggerAt: Date?
    /// 网络路径变化回调（在监听的私有队列上调用，需要自行切回主线程）
    var onPathChanged: (() -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(path)
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    private func handle(_ path: NWPath) {
        let key = Self.key(for: path)
        guard key != lastKey else { return }
        lastKey = key

        // 防抖：路径变化可能连续回调多次，至少间隔 5 秒再触发一次探测
        let now = Date()
        if let last = lastTriggerAt, now.timeIntervalSince(last) < 5 { return }
        lastTriggerAt = now
        onPathChanged?()
    }

    /// 路径指纹：状态 + 使用的网络类型，任何一项变化都视为网络切换
    private static func key(for path: NWPath) -> String {
        var parts: [String] = [path.status == .satisfied ? "up" : "down"]
        if path.usesInterfaceType(.wifi) { parts.append("wifi") }
        if path.usesInterfaceType(.cellular) { parts.append("cellular") }
        if path.usesInterfaceType(.wiredEthernet) { parts.append("ethernet") }
        if path.usesInterfaceType(.other) { parts.append("other") }
        return parts.joined(separator: ",")
    }
}
