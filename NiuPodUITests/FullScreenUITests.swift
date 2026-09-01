import XCTest

/// 界面布局的客观验证
///
/// 用 `-demoMode` 启动，不依赖真实 NAS。核心断言是「屏幕区与转盘区各占
/// 独立空间、互不重叠」——转盘不是浮层，内容永远不会被圆盘压住。
final class FullScreenUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demoMode"]
        app.launch()
    }

    // MARK: - 辅助

    /// 等主菜单渲染出来。
    ///
    /// `launch()` 返回时 App 可能还没画完首帧（模拟器负载高时能到几十秒），
    /// 此时直接 `tap()` 会打空；而且进入演示模式时 RootView 有 0.18s 转场，
    /// 动画进行中的点击同样会被吞掉。所以这里要等到元素真正可点击，
    /// 再额外静置一小会儿。
    @discardableResult
    private func waitForMainMenu() -> Bool {
        let item = app.staticTexts["歌曲"].firstMatch
        guard item.waitForExistence(timeout: 30) else { return false }
        var waited = 0.0
        while !item.isHittable && waited < 3.0 {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 0.1
        }
        Thread.sleep(forTimeInterval: 0.3)
        return true
    }

    /// 点菜单项并等下一页出现。
    ///
    /// 模拟器负载高时 XCUITest 会丢点击，实测每轮总有一两条用例因此挂掉，
    /// 且**挂的用例每次都不一样**——不是应用缺陷。应用逻辑是同步的
    /// （点按 → 直接 push），所以重试不会掩盖真实问题。
    @discardableResult
    private func tapAndWait(_ title: String,
                            until target: XCUIElement,
                            timeout: TimeInterval = 8) -> Bool {
        for _ in 0..<3 {
            app.staticTexts[title].firstMatch.tap()
            if target.waitForExistence(timeout: timeout) { return true }
        }
        return false
    }

    /// 走「主菜单 → 专辑 → 候鸟电台 → 夜航西飞 → 正在播放」。
    /// 每步都带重试：模拟器负载高时会丢点击，实测每轮总有一两条用例因此挂掉，
    /// 且挂的用例每次都不一样。
    @discardableResult
    private func enterNowPlaying() -> Bool {
        guard waitForMainMenu() else { return false }
        guard tapAndWait("专辑", until: app.staticTexts["候鸟电台"].firstMatch, timeout: 15) else { return false }
        guard tapAndWait("候鸟电台", until: app.staticTexts["夜航西飞"].firstMatch, timeout: 15) else { return false }
        return tapAndWait("夜航西飞", until: app.staticTexts["正在播放"].firstMatch)
    }

    // MARK: - 全屏

    func testAppFillsScreen() {
        // 缺 UILaunchScreen 时 App 会被按 320×480 等比缩放居中显示，
        // 此时 window 会明显小于 app.frame 且 y 有偏移
        let screen = app.frame
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(screen.width, 0)
        XCTAssertEqual(window.width, screen.width, accuracy: 1)
        XCTAssertEqual(window.height, screen.height, accuracy: 1)
        XCTAssertEqual(window.minY, screen.minY, accuracy: 1)
    }

    func testMenuRowSpansFullWidth() {
        // 菜单行文字左侧几乎贴边 → 没有被机身/外边距挤在中间
        let row = app.staticTexts["歌曲"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let screenWidth = app.windows.firstMatch.frame.width
        XCTAssertLessThan(row.frame.minX, 24, "菜单行左边距应很小，实测 \(row.frame.minX)")
        XCTAssertGreaterThan(screenWidth, 0)
    }

    // MARK: - 屏幕区 / 转盘区互不重叠

    func testScreenAndWheelAreSeparateRegions() {
        let wheel = app.otherElements["clickWheel"].firstMatch
        let last = app.staticTexts["设置"].firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        XCTAssertTrue(last.waitForExistence(timeout: 5))

        // 主菜单最后一项必须完整落在转盘上方
        XCTAssertLessThanOrEqual(last.frame.maxY, wheel.frame.minY + 1,
                                 "菜单最后一行不应与转盘重叠：last.maxY=\(last.frame.maxY) wheel.minY=\(wheel.frame.minY)")
    }

    func testAllMenuEntriesVisibleWithoutScrolling() {
        // 屏幕区高度要能一次容纳全部主菜单项
        for title in ["歌曲", "专辑", "歌手", "歌单", "风格", "收藏",
                      "搜索", "随机播放歌曲", "设置"] {
            let element = app.staticTexts[title].firstMatch
            guard element.waitForExistence(timeout: 5) else {
                XCTFail("缺少菜单项：\(title)")
                continue
            }
            XCTAssertTrue(element.isHittable,
                          "菜单项应一屏内完整可见（无需滚动）：\(title) frame=\(element.frame)")
        }
    }

    func testLongSongListStaysClearOfWheel() {
        XCTAssertTrue(waitForMainMenu(), "主菜单应在 30 秒内出现")
        app.staticTexts["歌曲"].firstMatch.tap()
        // 等列表真正渲染出来再滑动，否则 LazyVStack 还没实例化任何行
        XCTAssertTrue(app.staticTexts["夜航西飞"].firstMatch.waitForExistence(timeout: 15))
        let wheel = app.otherElements["clickWheel"].firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 15))

        // LazyVStack 只会实例化可见行，所以必须先滚到底再检查
        let scroll = app.scrollViews.firstMatch
        // 24 首歌一次 swipeUp 到不了底，多刷几轮
        for _ in 0..<8 { scroll.swipeUp(velocity: .fast) }

        // 所有可见的曲目行都必须完整落在转盘上方
        var checked = 0
        for title in Self.demoTrackTitles {
            let element = app.staticTexts[title].firstMatch
            guard element.exists, element.frame.width > 0, element.frame.minY > 0 else { continue }
            checked += 1
            XCTAssertLessThanOrEqual(element.frame.maxY, wheel.frame.minY + 1,
                                     "《\(title)》被转盘遮挡：maxY=\(element.frame.maxY) wheelMinY=\(wheel.frame.minY)")
        }
        XCTAssertGreaterThan(checked, 0, "应至少检查到一行曲目")
    }

    /// 演示数据里的全部曲目名（与 DemoData 保持一致）
    private static let demoTrackTitles = [
        "夜航西飞", "雨落无声", "潮汐信号", "午夜站台", "白色信封",
        "橘子汽水", "操场晚风", "单车与海", "蝉鸣十七",
        "旧巷灯火", "铁皮盒子", "长夜将尽", "写给明天的信",
        "山谷回声", "雾中列车", "极光观测", "雪线之上",
        "清晨六点", "一杯温水", "通勤路上", "窗台植物",
        "蓝色房间", "未寄出的信", "末班地铁", "冬至",
    ]

    func testClickWheelPinnedToBottom() {
        let wheel = app.otherElements["clickWheel"].firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))

        let screen = app.windows.firstMatch.frame
        let bottomGap = screen.maxY - wheel.frame.maxY
        XCTAssertLessThan(bottomGap, wheel.frame.height / 2,
                          "转盘应位于屏幕下半部，实测底部留白 \(bottomGap)")

        // 转盘直径占屏宽的比例：太小不好按，太大会挤掉屏幕区
        let ratio = wheel.frame.width / screen.width
        XCTAssertGreaterThan(ratio, 0.45, "转盘太小：占比 \(ratio)")
        XCTAssertLessThan(ratio, 0.9, "转盘太大：占比 \(ratio)")
    }

    func testScreenRegionTakesMajorityOfHeight() {
        // 「全屏」的实质：屏幕区要占掉大部分高度
        let wheel = app.otherElements["clickWheel"].firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        let screenHeight = app.windows.firstMatch.frame.height
        let screenRegion = wheel.frame.minY      // 转盘顶边即屏幕区下沿
        XCTAssertGreaterThan(screenRegion / screenHeight, 0.5,
                             "屏幕区应占一半以上高度，实测 \(screenRegion)/\(screenHeight)")
    }

    // MARK: - 基本交互

    func testCanNavigateIntoAlbums() {
        XCTAssertTrue(waitForMainMenu(), "主菜单应在 30 秒内出现")
        XCTAssertTrue(tapAndWait("专辑", until: app.staticTexts["候鸟电台"].firstMatch, timeout: 15),
                      "点「专辑」应进入专辑列表")
    }

    func testCanOpenNowPlayingFromAlbum() {
        XCTAssertTrue(enterNowPlaying(), "点曲目后应进入正在播放")
        XCTAssertTrue(app.otherElements["clickWheel"].exists)
    }

    /// 中心键在「封面 / 歌词」两层之间切换（第三层「选项」已移除）
    func testNowPlayingCenterTogglesCoverAndLyrics() {
        XCTAssertTrue(enterNowPlaying(), "应能一路进到正在播放页")

        let cover = app.otherElements["nowPlayingCover"].firstMatch
        let lyrics = app.otherElements["nowPlayingLyrics"].firstMatch
        let center = app.otherElements["centerButton"].firstMatch
        let hint = app.staticTexts["转盘 = 快进/快退 · 中心键 = 封面/歌词 · 长按 = 菜单"].firstMatch
        XCTAssertTrue(center.exists, "应有中心键")
        XCTAssertTrue(cover.waitForExistence(timeout: 8), "默认应显示封面层")
        XCTAssertTrue(hint.exists, "封面层应显示操作提示")

        center.tap()
        XCTAssertTrue(hint.waitForNonExistence(timeout: 8), "中心键应切走封面层（提示应消失）")
        let lyricsShown = lyrics.waitForExistence(timeout: 8)
            || app.scrollViews.firstMatch.exists
            || app.staticTexts["这首歌暂无歌词"].firstMatch.exists
        XCTAssertTrue(lyricsShown, "中心键应切到歌词层")
        XCTAssertFalse(cover.exists, "歌词层下不应同时存在封面层")

        center.tap()
        XCTAssertTrue(cover.waitForExistence(timeout: 8), "中心键应切回封面层")
        XCTAssertTrue(hint.waitForExistence(timeout: 8), "回到封面层后应恢复操作提示")
    }

    /// 标题跟随播放状态：播放 → 已暂停播放 → 播放
    func testNowPlayingTitleFollowsPlaybackState() {
        XCTAssertTrue(enterNowPlaying(), "应能一路进到正在播放页")
        XCTAssertTrue(app.staticTexts["正在播放"].firstMatch.waitForExistence(timeout: 8),
                      "播放中标题应为「正在播放」")

        // 点转盘下键 = 播放/暂停
        let wheel = app.otherElements["clickWheel"].firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        let playPause = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
        playPause.tap()
        XCTAssertTrue(app.staticTexts["已暂停播放"].firstMatch.waitForExistence(timeout: 8),
                      "暂停后标题应为「已暂停播放」")

        playPause.tap()
        XCTAssertTrue(app.staticTexts["正在播放"].firstMatch.waitForExistence(timeout: 8),
                      "恢复播放后标题应回到「正在播放」")
    }

    /// 播放页长按中心键也能呼出曲目操作菜单
    func testNowPlayingLongPressCenterOpensTrackActions() {
        XCTAssertTrue(enterNowPlaying(), "应能一路进到正在播放页")

        let center = app.otherElements["centerButton"].firstMatch
        XCTAssertTrue(center.waitForExistence(timeout: 5))
        center.press(forDuration: 0.8)

        XCTAssertTrue(app.staticTexts["播放"].firstMatch.waitForExistence(timeout: 8),
                      "长按中心键应弹出曲目操作菜单")
        XCTAssertTrue(app.staticTexts["取消"].firstMatch.exists)

        // 点「取消」关闭菜单，回到封面层
        app.staticTexts["取消"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["播放"].firstMatch.waitForNonExistence(timeout: 8),
                      "取消后菜单应关闭")
        XCTAssertTrue(app.otherElements["nowPlayingCover"].firstMatch.waitForExistence(timeout: 8),
                      "关闭菜单后应回到封面层")
    }

    /// 退出登录改为 iPod 风格确认框：打开 / 取消
    func testLogoutDialogIPodStyleAndCancel() {
        XCTAssertTrue(waitForMainMenu(), "主菜单应在 30 秒内出现")
        let logout = app.staticTexts["退出演示模式"].firstMatch
        XCTAssertTrue(tapAndWait("设置", until: logout, timeout: 15), "点「设置」应进入设置页")
        XCTAssertTrue(tapAndWait("退出演示模式", until: app.staticTexts["将返回登录页。"].firstMatch, timeout: 8))

        let message = app.staticTexts["将返回登录页。"].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5), "应弹出 iPod 风格确认框")
        XCTAssertTrue(app.staticTexts["取消"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["退出"].firstMatch.exists)

        app.staticTexts["取消"].firstMatch.tap()
        XCTAssertTrue(message.waitForNonExistence(timeout: 5), "取消后确认框应关闭")
        XCTAssertTrue(app.staticTexts["退出演示模式"].firstMatch.exists, "应回到设置页")
    }

    /// 确认退出后回到登录页
    func testLogoutConfirmReturnsToLogin() {
        XCTAssertTrue(waitForMainMenu(), "主菜单应在 30 秒内出现")
        let logout = app.staticTexts["退出演示模式"].firstMatch
        XCTAssertTrue(tapAndWait("设置", until: logout, timeout: 20), "点「设置」应进入设置页")
        XCTAssertTrue(tapAndWait("退出演示模式", until: app.staticTexts["将返回登录页。"].firstMatch, timeout: 8))
        let message = app.staticTexts["将返回登录页。"].firstMatch
        app.staticTexts["退出"].firstMatch.tap()

        let login = app.buttons["连接"].firstMatch
        XCTAssertTrue(login.waitForExistence(timeout: 8), "确认退出后应回到登录页")
    }

    /// 登录页整块白框都可点击聚焦（回归：以前只有文字区可点，白框上下大片点不动）
    func testLoginFieldWholeBoxFocusable() {
        app.launchArguments = ["-forceLogin"]
        app.launch()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "登录页应有输入框")

        // 点白色框上部（不在文字区，仍在 40pt 白框内），应能聚焦弹出键盘
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.3)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 6),
                      "点击白框上部也应弹出键盘")

        // 聚焦后能正常输入
        app.typeText("abc123")
        XCTAssertEqual(field.value as? String, "abc123", "聚焦后应能输入")
    }

    /// 转动转盘不应误触 MENU（回归：曾用手势「首尾直线距离」判定点击，
    /// 转一圈回到出发点时距离≈0，松手就被判成点 MENU 而退回上一级）
    func testRotatingWheelDoesNotTriggerMenu() {
        XCTAssertTrue(waitForMainMenu(), "主菜单应在 30 秒内出现")
        XCTAssertTrue(tapAndWait("歌曲", until: app.staticTexts["夜航西飞"].firstMatch, timeout: 15),
                      "点「歌曲」应进入曲目列表")

        let wheel = app.otherElements["clickWheel"].firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        // 沿环走一整圈：上 → 右 → 下 → 左 → 回上（每段各转 90°）
        let stops = [
            CGVector(dx: 0.5, dy: 0.12),    // 上：MENU
            CGVector(dx: 0.88, dy: 0.5),    // 右
            CGVector(dx: 0.5, dy: 0.88),    // 下
            CGVector(dx: 0.12, dy: 0.5),    // 左
            CGVector(dx: 0.5, dy: 0.12),    // 回到起点
        ].map { wheel.coordinate(withNormalizedOffset: $0) }

        for (from, to) in zip(stops, stops.dropFirst()) {
            from.press(forDuration: 0.05, thenDragTo: to)
        }

        // 仍在歌曲列表，且没有退到主菜单
        XCTAssertTrue(app.staticTexts["夜航西飞"].firstMatch.exists,
                      "转一圈后应留在歌曲列表，不应误触 MENU 返回")
        XCTAssertFalse(app.staticTexts["设置"].firstMatch.exists, "不应退回主菜单")
    }

    /// 打印真实坐标，便于排查布局（不做断言）
    func testPrintLayoutMetrics() {
        let wheel = app.otherElements["clickWheel"].firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        let center = app.otherElements["centerButton"].firstMatch
        var lines = ["[layout] app=\(app.frame) window=\(app.windows.firstMatch.frame)",
                     "[layout] wheel=\(wheel.frame)"]
        if center.exists {
            lines.append("[layout] centerButton=\(center.frame)")
        }
        for title in ["歌曲", "设置"] {
            let element = app.staticTexts[title].firstMatch
            if element.waitForExistence(timeout: 3) {
                lines.append("[layout] \(title)=\(element.frame) hittable=\(element.isHittable)")
            }
        }
        print(lines.joined(separator: "\n"))
    }
}
