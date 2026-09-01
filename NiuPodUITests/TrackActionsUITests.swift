import XCTest

/// 曲目操作闭环的验证
///
/// 重点覆盖曾经的死角：收藏/取消收藏以前只能在「正在播放 → 中心键切两下 →
/// 选项」里做，收藏列表本身没有任何移除入口。现在改成在任意曲目列表
/// **长按中心键**呼出菜单，这组测试守着这条路径。
final class TrackActionsUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demoMode"]
        app.launch()
    }

    // MARK: - 工具

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

    private func wheel() -> XCUIElement {
        let element = app.otherElements["clickWheel"].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 15))
        return element
    }

    /// 长按转盘中心键
    private func longPressCenter() {
        wheel().press(forDuration: 0.8)
    }

    /// 点转盘上部 = MENU
    private func tapMenuButton() {
        wheel().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
    }

    private func enterSongList() {
        XCTAssertTrue(waitForMainMenu(), "主菜单应在 30 秒内出现")
        XCTAssertTrue(tapAndWait("歌曲", until: app.staticTexts["夜航西飞"].firstMatch, timeout: 15),
                      "点「歌曲」应进入曲目列表")
    }

    // MARK: - 测试

    func testLongPressCenterOpensTrackActions() {
        enterSongList()
        longPressCenter()

        // 菜单应出现：曲目名 + 三个操作项
        XCTAssertTrue(app.staticTexts["播放"].firstMatch.waitForExistence(timeout: 5),
                      "长按中心键应弹出曲目操作菜单")
        XCTAssertTrue(app.staticTexts["取消"].firstMatch.exists)

        let favorite = app.staticTexts["收藏"].firstMatch.exists
        let unfavorite = app.staticTexts["取消收藏"].firstMatch.exists
        XCTAssertTrue(favorite || unfavorite, "菜单里应有收藏或取消收藏")
    }

    /// 收藏 → 取消收藏 的完整闭环（演示数据里第一首「夜航西飞」初始已收藏）
    func testCanUnfavoriteThenRefavoriteFromList() {
        enterSongList()

        // 第一次长按：应显示「取消收藏」（该曲已收藏）
        longPressCenter()
        let unfavorite = app.staticTexts["取消收藏"]
        XCTAssertTrue(unfavorite.waitForExistence(timeout: 5), "已收藏曲目应显示「取消收藏」")

        // 取消收藏
        unfavorite.tap()
        XCTAssertTrue(unfavorite.waitForNonExistence(timeout: 5), "执行后菜单应关闭")

        // 再一次长按：这次应显示「收藏」
        longPressCenter()
        let favorite = app.staticTexts["收藏"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5), "取消收藏后应显示「收藏」")

        // 重新收藏
        favorite.tap()
        XCTAssertTrue(favorite.waitForNonExistence(timeout: 5))

        // 回到「取消收藏」状态，说明两边都真的生效了
        longPressCenter()
        XCTAssertTrue(unfavorite.waitForExistence(timeout: 5), "重新收藏后应回到「取消收藏」")
    }

    /// 菜单可以用 MENU 关闭，不会把用户困住
    func testMenuDismissibleWithMENU() {
        enterSongList()
        longPressCenter()
        XCTAssertTrue(app.staticTexts["播放"].firstMatch.waitForExistence(timeout: 5))

        tapMenuButton()
        XCTAssertTrue(app.staticTexts["播放"].firstMatch.waitForNonExistence(timeout: 5),
                      "MENU 应能关闭操作菜单")

        // 关掉后转盘恢复成列表滚动
        XCTAssertTrue(app.staticTexts["夜航西飞"].firstMatch.exists)
    }

    /// 收藏列表里也能移除 —— 这正是之前完全没出口的地方
    func testCanRemoveFromFavoritesList() {
        XCTAssertTrue(waitForMainMenu(), "主菜单应在 30 秒内出现")
        app.staticTexts["收藏"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["夜航西飞"].firstMatch.waitForExistence(timeout: 15))

        longPressCenter()
        let unfavorite = app.staticTexts["取消收藏"]
        XCTAssertTrue(unfavorite.waitForExistence(timeout: 5),
                      "收藏列表里长按也应能取消收藏")
        unfavorite.tap()
    }

    /// 生成一张「长按菜单」的截图，方便人工确认视觉（写入 /tmp，不参与断言）
    func testCaptureActionMenuScreenshot() throws {
        try? FileManager.default.createDirectory(atPath: "/tmp/niupod-shots",
                                                 withIntermediateDirectories: true)
        enterSongList()
        longPressCenter()
        // 模拟器负载高时菜单弹出会慢，这里给足超时
        XCTAssertTrue(app.staticTexts["播放"].firstMatch.waitForExistence(timeout: 20))
        let shot = XCUIScreen.main.screenshot()
        try shot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/niupod-shots/actions_menu.png"))
    }

    /// 空列表时长按不应该崩，也不应该弹出菜单
    func testLongPressOnEmptyListDoesNothing() {
        // 演示模式里没有空列表，用搜索构造一个（搜一个不存在的词）
        XCTAssertTrue(waitForMainMenu(), "主菜单应在 30 秒内出现")
        let field = app.textFields.firstMatch
        XCTAssertTrue(tapAndWait("搜索", until: field, timeout: 15), "点「搜索」应进入搜索页")
        field.tap()
        // 直接敲换行触发 onSubmit，比去找键盘上的 Search 按钮稳
        field.typeText("zzzzz\n")

        // 等「没有找到结果」稳定出现
        XCTAssertTrue(app.staticTexts["没有找到结果"].waitForExistence(timeout: 10))
        longPressCenter()
        // 不应弹出菜单
        XCTAssertFalse(app.staticTexts["播放"].firstMatch.exists)
    }

    /// 搜索框整条都可点聚焦（回归：以前只有文字区可点，点框上部没反应）
    func testSearchFieldWholeBoxFocusable() {
        XCTAssertTrue(waitForMainMenu(), "主菜单应在 30 秒内出现")
        let field = app.textFields.firstMatch
        XCTAssertTrue(tapAndWait("搜索", until: field, timeout: 15), "点「搜索」应进入搜索页")

        // 点搜索框上部（非文字区），应能聚焦弹出键盘
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.3)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 6),
                      "点击搜索框上部也应弹出键盘")
    }

    /// 键盘弹出时搜索结果必须可见（回归：系统键盘避让 + 手动让位双重压缩
    /// 会把列表压成 0 高度 → 白屏）
    func testSearchResultsVisibleWhileKeyboardUp() {
        XCTAssertTrue(waitForMainMenu(), "主菜单应在 30 秒内出现")
        let field = app.textFields.firstMatch
        XCTAssertTrue(tapAndWait("搜索", until: field, timeout: 15), "点「搜索」应进入搜索页")
        field.tap()
        // 输入能命中演示曲目的关键词，不回车，保持键盘弹出
        field.typeText("夜")

        // 防抖约 0.45s 后自动出结果，且键盘仍处于弹出状态
        let row = app.staticTexts["夜航西飞"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(app.keyboards.firstMatch.exists)

        // 结果行必须真实渲染（高度 > 0，而不是被压成白屏）
        XCTAssertGreaterThan(row.frame.height, 0)
        XCTAssertGreaterThan(row.frame.maxY, row.frame.minY)
    }
}

extension XCUIElement {
    /// 等待元素消失
    @discardableResult
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }
}
