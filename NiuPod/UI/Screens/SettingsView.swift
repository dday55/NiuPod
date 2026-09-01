import SwiftUI

struct SettingsView: View {
    @Environment(Session.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(AudioPlayer.self) private var player
    @Environment(PodNavigation.self) private var nav
    @Environment(WheelController.self) private var wheel

    @State private var selected = 0
    @State private var confirmLogout = false
    /// 确认框内选中行：0 = 取消，1 = 退出
    @State private var confirmIndex = 0

    private struct Entry {
        let id: String
        let title: String
        let detail: String?
        let action: () -> Void
    }

    /// 连接状态描述：优先显示最近一次探测/自动切换的链路（登录时是初始链路，
    /// 自动切换后是新链路），没有才退回 中继/直连。
    private var connectionDetail: String? {
        if let method = session.lastProbeMethod, !method.isEmpty {
            return method
        }
        return session.credentials.relayMode ? "中继" : "直连"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// 「重新载入音乐库」的状态反馈：载入中 / 失败 / 上次更新时间
    private var reloadDetail: String? {
        if library.isLoading { return "载入中…" }
        if let err = library.errorMessage, !err.isEmpty { return "失败：\(err)" }
        if let last = library.lastLoadedAt { return "更新于 \(Self.timeFormatter.string(from: last))" }
        return nil
    }

    /// 「立即重连」的状态反馈：重连中 / 会话消息（成功会清空，失败会显示原因）
    private var reconnectDetail: String? {
        if session.isWorking { return "重连中…" }
        if let msg = session.message, !msg.isEmpty { return msg }
        return nil
    }

    private var entries: [Entry] {
        [
            Entry(id: "connection", title: "连接", detail: connectionDetail) {
                nav.push(.connection)
            },
            Entry(id: "reload", title: "重新载入音乐库", detail: reloadDetail) {
                library.reload(force: true)
            },
            Entry(id: "reconnect", title: "立即重连", detail: reconnectDetail) {
                Task { await session.reconnect() }
            },
            Entry(id: "cache", title: "清除封面缓存", detail: nil) {
                ArtworkLoader.clearMemoryCache()
                ArtworkLoader.clearDiskCache()
            },
            Entry(id: "about", title: "关于", detail: nil) { nav.push(.about) },
            Entry(id: "logout",
                  title: session.isDemo ? "退出演示模式" : "退出登录",
                  detail: session.isDemo ? nil : session.credentials.username) {
                confirmLogout = true
            },
        ]
    }

    var body: some View {
        ZStack {
            PodScreen(title: "设置") {
                PodMenuList(items: menuItems, selected: $selected) { index in
                    entries[index].action()
                }
            }

            if confirmLogout {
                PodConfirmDialog(
                    title: session.isDemo ? "退出演示模式" : "退出登录",
                    message: session.isDemo ? "将返回登录页。" : "将清除本机保存的登录令牌与安全码。",
                    confirmTitle: "退出",
                    selected: confirmIndex,
                    onSelect: { index in
                        confirmIndex = index
                        if index == 1 { performLogout() } else { confirmLogout = false }
                    },
                    onCancel: { confirmLogout = false }
                )
                .transition(.opacity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("logoutDialog")
            }
        }
        .animation(.easeOut(duration: 0.15), value: confirmLogout)
        .onAppear(perform: bindWheel)
        // 确认框开合要重新绑定转盘，否则还停留在「设置列表」语义上
        .onChange(of: confirmLogout) { _, _ in bindWheel() }
        .onChange(of: entries.count) { _, _ in
            if selected >= entries.count { selected = max(0, entries.count - 1) }
            bindWheel()
        }
    }

    // MARK: - 转盘

    private func bindWheel() {
        wheel.isScrubbing = false

        guard !confirmLogout else {
            // 确认框模式：旋转选行（取消/退出），中心键执行，MENU 或点空白取消
            wheel.onRotate = { [self] delta in
                confirmIndex = max(0, min(1, confirmIndex + delta))
            }
            wheel.onCenter = { [self] in
                if confirmIndex == 1 { performLogout() } else { confirmLogout = false }
            }
            wheel.onMenu = { [self] in confirmLogout = false }
            wheel.onLongCenter = nil
            return
        }

        // 设置列表模式
        wheel.onRotate = { [self] delta in
            selected = max(0, min(entries.count - 1, selected + delta))
        }
        wheel.onCenter = { [self] in
            guard entries.indices.contains(selected) else { return }
            entries[selected].action()
        }
        wheel.onMenu = { [self] in nav.pop() }
        wheel.onLongCenter = nil
    }

    private func performLogout() {
        confirmLogout = false
        player.stop()
        library.reset()
        if session.isDemo {
            session.exitDemo()
        } else {
            session.logout()
        }
        library.isDemo = false
        player.isDemo = false
        nav.popToRoot()
    }

    private var menuItems: [PodMenuItem] {
        entries.map {
            PodMenuItem(id: $0.id, title: $0.title, subtitleRight: $0.detail, showDisclosure: true)
        }
    }
}

// MARK: - 关于

struct AboutView: View {
    @Environment(Session.self) private var session
    @Environment(WheelController.self) private var wheel
    @Environment(PodNavigation.self) private var nav

    var body: some View {
        PodScreen(title: "关于") {
            VStack(alignment: .leading, spacing: 8) {
                InfoLine(label: "版本", value: appVersion)
                InfoLine(label: "账号", value: session.credentials.username.isEmpty ? "—" : session.credentials.username)
                InfoLine(label: "服务器", value: session.credentials.baseUrl.isEmpty ? "—" : session.credentials.baseUrl)
                InfoLine(label: "链路", value: session.credentials.relayMode ? "FN Connect 中继" : "直连")
                if let method = session.lastProbeMethod {
                    InfoLine(label: "探测", value: method)
                }
                Divider().background(PodTheme.rowSeparator)
                Text("NiuPod 是飞牛私有云（FNOS）音乐服务的第三方客户端，"
                     + "通过 FN Connect 自动选择内网 / 公网 IPv6 / 公网 IPv4 / 中继中可用的最优链路。"
                     + "本项目与飞牛官方无关联。")
                    .font(.system(size: 10))
                    .foregroundStyle(PodTheme.rowSecondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
        }
        .onAppear {
            // 三个都要显式绑定：以前只清了 rotate/center，onMenu 沿用上一个
            // 页面留下的闭包，碰巧能用但属于隐式依赖
            wheel.onRotate = nil
            wheel.onCenter = nil
            wheel.onLongCenter = nil
            wheel.onMenu = { nav.pop() }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}

struct InfoLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(PodTheme.rowSecondary)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - iPod 风格确认对话框

/// iPod 风格确认框：标题栏 + 消息 + 两行选项（取消 / 确认），
/// 与曲目操作菜单同一套视觉语言（蓝渐变选中、实心 ✕ 取消图标）。
struct PodConfirmDialog: View {
    let title: String
    let message: String
    let confirmTitle: String
    let selected: Int
    let onSelect: (Int) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            // 遮罩：点空白处也能取消
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(spacing: 0) {
                    // 标题头：与菜单页一致的蓝渐变
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PodTheme.titleText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(PodTheme.titleGradient)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(PodTheme.titleDivider).frame(height: 1)
                        }

                    // 消息
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(PodTheme.rowSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)

                    // 取消（实心 ✕，与曲目操作菜单一致）
                    optionRow(index: 0, customIcon: true, icon: "xmark",
                              title: "取消", destructive: false)
                    // 确认（退出）
                    optionRow(index: 1, customIcon: false,
                              icon: "rectangle.portrait.and.arrow.right.fill",
                              title: confirmTitle, destructive: true)
                }
                .background(PodTheme.screenBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.28), radius: 16, x: 0, y: 6)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
        }
    }

    private func optionRow(index: Int, customIcon: Bool, icon: String,
                           title: String, destructive: Bool) -> some View {
        HStack(spacing: 8) {
            if customIcon {
                SolidX()
                    .fill(index == selected ? PodTheme.selectedText : PodTheme.rowText)
                    .frame(width: 12, height: 12)
                    // 与 SF Symbol 图标同占 16pt 宽，保证两行图标中心对齐
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
            }
            Text(title)
                .font(PodFont.row(15, selected: index == selected))
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: PodTheme.rowHeight)
        .foregroundStyle(
            index == selected
                ? PodTheme.selectedText
                : (destructive ? Color(red: 0.72, green: 0.18, blue: 0.18) : PodTheme.rowText)
        )
        .background {
            if index == selected {
                PodTheme.selectedGradient
            } else {
                Color.clear
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PodTheme.rowSeparator)
                .frame(height: 0.5)
                .opacity(index == selected ? 0 : 1)
        }
        .clipShape(Rectangle())
        .contentShape(Rectangle())
        .onTapGesture { onSelect(index) }
    }
}
