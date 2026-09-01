import SwiftUI

@main
struct NiuPodApp: App {
    @State private var session = Session()
    @State private var library = LibraryStore()
    @State private var player = AudioPlayer()
    @State private var pathObserver = NetworkPathObserver()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(library)
                .environment(player)
                .task { await setup() }
        }
    }

    private func setup() async {
        // 播放引擎 / 数据层都从这里拿凭据，登录与重连后自动生效
        player.credentialsProvider = { session.credentials }
        library.credentialsProvider = { session.credentials }
        player.onUnauthorized = { session.handleUnauthorized() }
        library.onUnauthorized = { session.handleUnauthorized() }

        // 网络超时/断连时自动切换链路：更新凭据、持久化，让后续请求与设置页状态走新链路
        await FailoverCoordinator.shared.register { [weak session] newCreds, method in
            Task { @MainActor in
                guard let session else { return }
                session.credentials = newCreds
                session.lastProbeMethod = method   // 设置页「连接」/关于页「探测」会随之刷新
                session.message = "网络超时，已自动切换到 \(newCreds.baseUrl)（\(method)）"
                CredentialsStore.save(newCreds)
            }
        }

        // 网络切换（如外网 → 内网 Wi-Fi）时自动重新探测：内网可用就优先切内网
        pathObserver.onPathChanged = { [weak session] in
            Task { @MainActor in
                guard let session, session.isLoggedIn else { return }
                await session.reconnect()
            }
        }
        pathObserver.start()

        // UI 测试专用启动参数：xcrun simctl launch <udid> com.niupod -demoMode
        // （产品界面没有演示模式入口，这份数据通道只服务无 NAS 环境的 UI 测试）
        if CommandLine.arguments.contains("-demoMode") {
            enterDemo()
            return
        }

        // 调试用启动参数：-forceLogin 强制清掉凭据进入登录页（UI 测试登录流程用）
        if CommandLine.arguments.contains("-forceLogin") {
            session.logout()
        }

        await session.restoreAndVerifyIfPossible()
        if session.isLoggedIn { library.reload() }
    }

    private func enterDemo() {
        session.enterDemo()
        library.isDemo = true
        player.isDemo = true
        library.reload()
    }
}
