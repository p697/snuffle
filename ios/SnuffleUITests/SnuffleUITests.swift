import StoreKitTest
import XCTest

/// End-to-end checks in demo mode, where every number is made up and every scenario is reproducible.
@MainActor
final class SnuffleUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState", "-demo"] + arguments
        app.launch()
        return app
    }

    private func refresh(_ app: XCUIApplication) {
        let button = app.otherElements["refreshButton"].firstMatch.exists ? app.otherElements["refreshButton"] : app.buttons["refreshButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        // Three cards reveal one after another; wait for the status line to report the finished refresh.
        let status = app.staticTexts["refreshStatus"]
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH '刚刚'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 25), .completed, "refresh did not finish: \(status.label)")
    }

    func testWelcomeOffersDemoAndConnect() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetState"]
        app.launch()
        XCTAssertTrue(app.buttons["startConnecting"].waitForExistence(timeout: 5))
        app.buttons["tryDemo"].tap()
        XCTAssertTrue(app.staticTexts["今日"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["leaveDemo"].exists)
    }

    func testRefreshCountsAndShowsCards() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Lumen Notes"].waitForExistence(timeout: 5))
        refresh(app)
        XCTAssertTrue(app.staticTexts["refreshStatus"].label.contains("第 1 次"))
        refresh(app)
        XCTAssertTrue(app.staticTexts["refreshStatus"].label.contains("第 2 次"))
        attach(app, name: "home-after-refresh")
    }

    func testFailedSourceIsNamedOnTheCard() {
        let app = launch(["-scenario", "failure"])
        refresh(app)
        XCTAssertTrue(app.buttons["RevenueCat 没连上 · 重试"].waitForExistence(timeout: 5))
        attach(app, name: "home-failure")
    }

    func testQuietRefreshSaysNothingChanged() {
        let app = launch(["-scenario", "quiet"])
        refresh(app)
        refresh(app)
        XCTAssertTrue(app.staticTexts["refreshStatus"].label.contains("第 2 次"))
    }

    func testTabsAndReply() {
        let app = launch()
        refresh(app)
        app.buttons["tab-收入"].tap()
        XCTAssertTrue(app.staticTexts["今天的订单"].waitForExistence(timeout: 5))
        attach(app, name: "money")
        app.buttons["tab-评论"].tap()
        let reply = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'reply-'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        attach(app, name: "reviews")
        reply.tap()
        // Drafting is hidden (Feature.replyDrafts), so the reply is written by hand.
        XCTAssertFalse(app.buttons["draftReply"].exists)
        let field = app.textViews["replyText"]
        field.tap()
        field.typeText("Thanks for the review!")
        attach(app, name: "reply")
        app.buttons["publishReply"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '发布到'")).firstMatch.tap()
        // An answered review leaves the to-answer list; it shows its reply under 全部.
        XCTAssertTrue(app.buttons["全部"].waitForExistence(timeout: 5))
        app.buttons["全部"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '你的回复'")).firstMatch.waitForExistence(timeout: 5))
        attach(app, name: "reviews-replied")
        app.buttons["tab-项目"].tap()
        let row = app.collectionViews.cells.containing(.staticText, identifier: "Pocket Ferry").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["数据来自"].waitForExistence(timeout: 5))
        app.buttons["7 天"].tap()
        XCTAssertTrue(app.staticTexts["每日新增用户"].waitForExistence(timeout: 5))
        attach(app, name: "project-detail-week")
    }

    /// Walks every preview page with the local StoreKit configuration, so prices and the trial are real.
    func testPaywallPreviewsAndPlans() throws {
        #if targetEnvironment(simulator)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        try XCTSkipIf(os.majorVersion == 26 && os.minorVersion == 5,
                      "StoreKitTest fails on the iOS 26.5 simulator (SKInternalErrorDomain 3); run on iOS 18 or 26.6+.")
        #endif
        let session = try SKTestSession(configurationFileNamed: "Products")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()

        let app = launch()
        XCTAssertTrue(app.staticTexts["Lumen Notes"].waitForExistence(timeout: 5))
        app.buttons["设置"].tap()
        app.buttons["upgradePro"].tap()

        // Opened from settings: the home screen page, yearly selected with its free week.
        let purchase = app.buttons["purchase"]
        XCTAssertTrue(purchase.waitForExistence(timeout: 5))
        let trial = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '免费试用 7 天'"), object: purchase)
        XCTAssertEqual(XCTWaiter.wait(for: [trial], timeout: 10), .completed, "button says \(purchase.label)")
        XCTAssertTrue(app.buttons["page-desk"].isSelected)
        XCTAssertTrue(app.staticTexts["先免费 7 天"].exists)
        XCTAssertTrue(app.buttons["previewRefresh"].exists)
        attach(app, name: "paywall-desk-medium")
        app.buttons["widgetSize-小号"].tap()
        attach(app, name: "paywall-desk-small")

        app.buttons["plan-ai.snuffle.pro.monthly"].tap()
        XCTAssertEqual(purchase.label, "订阅 · $1.99/月")
        app.buttons["plan-ai.snuffle.pro.lifetime"].tap()
        XCTAssertEqual(purchase.label, "买断 · $29.99")
        app.buttons["plan-ai.snuffle.pro.yearly"].tap()

        app.buttons["page-lock"].tap()
        attach(app, name: "paywall-lock")
        app.buttons["page-history"].tap()
        XCTAssertTrue(app.staticTexts["每日新增用户"].waitForExistence(timeout: 5))
        attach(app, name: "paywall-history")
        app.buttons["page-projects"].tap()
        XCTAssertTrue(app.staticTexts["项目想加多少加多少"].waitForExistence(timeout: 5))
        attach(app, name: "paywall-projects")

        app.buttons["closePaywall"].tap()
        XCTAssertFalse(purchase.waitForExistence(timeout: 2))
    }

    /// Imports a real App Store Connect key through the UI, picks an app and refreshes. Runs only when
    /// `TEST_RUNNER_SNUFFLE_LIVE_ASC_*` variables are passed to xcodebuild; values are typed, never logged.
    func testLiveAppStoreKeyImport() throws {
        let env = ProcessInfo.processInfo.environment
        guard let pem = env["SNUFFLE_LIVE_ASC_PEM"], let issuer = env["SNUFFLE_LIVE_ASC_ISSUER"], let keyId = env["SNUFFLE_LIVE_ASC_KEY_ID"],
              let appName = env["SNUFFLE_LIVE_ASC_APP"] else {
            throw XCTSkip("No live App Store Connect key in the environment")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-resetState"]
        app.launch()
        app.buttons["startConnecting"].tap()
        app.buttons["connect-appStore"].tap()

        let keyField = app.textFields["密钥 ID，例如 2X9R4HXF34"]
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        keyField.tap()
        keyField.typeText(keyId)
        let issuerField = app.textFields["Issuer ID"]
        issuerField.tap()
        issuerField.typeText(issuer)
        let pemField = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields["或者直接粘贴 .p8 文件内容"]
        pemField.tap()
        UIPasteboard.general.string = pem
        pemField.press(forDuration: 1.2)
        let paste = app.menuItems["粘贴"].exists ? app.menuItems["粘贴"] : app.menuItems["Paste"]
        if paste.waitForExistence(timeout: 3) { paste.tap() } else { pemField.typeText(pem) }
        if app.buttons["允许粘贴"].waitForExistence(timeout: 2) { app.buttons["允许粘贴"].tap() }

        app.buttons["导入并读取 App 列表"].tap()
        let appRow = app.buttons.containing(.staticText, identifier: appName).firstMatch
        XCTAssertTrue(appRow.waitForExistence(timeout: 20), "app list did not load")
        attach(app, name: "live-asc-apps")
        appRow.tap()

        XCTAssertTrue(app.staticTexts["已连接 · \(appName)"].waitForExistence(timeout: 5))
        app.buttons["下一步"].tap()
        app.buttons["finishProject"].tap()

        // A store-only project shows reviews to answer as its big number, described underneath.
        let caption = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '条评论待回复'")).firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 30), "refresh did not show reviews")
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH '刚刚'"), object: app.staticTexts["refreshStatus"])
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 30), .completed)
        attach(app, name: "live-asc-home")
        app.buttons["tab-评论"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'reply-'")).firstMatch.waitForExistence(timeout: 5))
        attach(app, name: "live-asc-reviews")
    }

    /// Every tab scrolls its last row clear of the tab bar and the refresh button.
    func testEveryTabScrollsClearOfTheTabBar() {
        let app = launch()
        refresh(app)
        for tab in ["今日", "收入", "评论", "项目"] {
            app.buttons["tab-\(tab)"].tap()
            for _ in 0..<6 { app.swipeUp(velocity: .fast) }
            sleep(1)
            attach(app, name: "bottom-\(tab)")
        }
        // The last row of 今日 sits fully above the bar once scrolled to the end.
        app.buttons["tab-今日"].tap()
        for _ in 0..<6 { app.swipeUp(velocity: .fast) }
        sleep(1)
        let last = app.buttons["leaveDemo"]
        XCTAssertTrue(last.isHittable)
        XCTAssertLessThanOrEqual(last.frame.maxY, app.buttons["tab-今日"].frame.minY)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
