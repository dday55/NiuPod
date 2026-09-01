import SwiftUI

/// 连接诊断页
///
/// 完整探测 FNID 下的所有链路（内网 / 公网 IPv6 / 公网 IPv4 / 中继），
/// 逐条展示可达性与耗时，并允许临时关闭某个分组。
struct ConnectionView: View {
    @Environment(Session.self) private var session
    @Environment(WheelController.self) private var wheel

    @State private var selected = 0
    @State private var results: [ProbeCandidateResult] = []
    @State private var isProbing = false
    @State private var errorMessage: String?

    private struct Entry: Identifiable {
        let id: String
        let title: String
        var detail: String? = nil
        var action: (() -> Void)? = nil
    }

    private var entries: [Entry] {
        var list: [Entry] = [
            Entry(id: "addr", title: "当前地址", detail: session.credentials.baseUrl.isEmpty ? "未连接" : session.credentials.baseUrl),
            Entry(id: "mode", title: "连接方式", detail: session.credentials.relayMode ? "中继" : "直连"),
            Entry(id: "fnid", title: "FNID", detail: session.credentials.fnId.isEmpty ? "（手动地址）" : session.credentials.fnId),
            Entry(id: "probe", title: isProbing ? "探测中…" : "重新探测全部链路") { Task { await runProbe() } },
        ]

        // 分组开关
        let disabled = CredentialsStore.disabledGroups
        for group in ProbeCandidateGroup.allCases {
            let isOff = disabled.contains(group)
            list.append(Entry(id: "group-\(group.rawValue)", title: "分组 · \(group.title)",
                              detail: isOff ? "已关闭" : "启用") {
                var set = CredentialsStore.disabledGroups
                if isOff { set.remove(group) } else { set.insert(group) }
                CredentialsStore.disabledGroups = set
            })
        }

        if let errorMessage {
            list.append(Entry(id: "error", title: "探测失败", detail: errorMessage))
        }

        // 探测结果
        for r in results {
            list.append(Entry(
                id: "result-\(r.address)",
                title: "\(r.isReachable ? "✓" : "✗") \(r.description)",
                detail: r.isReachable ? "\(r.elapsedMs)ms" : (r.error ?? "不可达")
            ))
        }
        return list
    }

    var body: some View {
        PodScreen(title: "连接") {
            PodMenuList(items: menuItems, selected: $selected) { index in
                entries[index].action?()
            }
        }
        .podWheel(selected: $selected, count: entries.count) { index in
            entries[index].action?()
        }
        .task { await runProbe() }
    }

    private var menuItems: [PodMenuItem] {
        entries.map {
            PodMenuItem(id: $0.id, title: $0.title, subtitleRight: $0.detail)
        }
    }

    private func runProbe() async {
        guard !session.credentials.fnId.isEmpty else {
            errorMessage = "当前使用手动地址，无法探测其他链路"
            return
        }
        guard !isProbing else { return }
        isProbing = true
        errorMessage = nil
        defer { isProbing = false }

        do {
            let (candidates, _) = try await session.diagnoseAllCandidates()
            results = candidates
        } catch {
            errorMessage = error.localizedDescription
            results = []
        }
    }
}
