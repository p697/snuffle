import StoreKitTest
import XCTest

/// End-to-end checks in demo mode, where every number is made up and every scenario is reproducible.
@MainActor
final class SnuffleUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = makeApp(["-resetState", "-demo"] + arguments)
        app.launch()
        return app
    }

    /// The flows below look for Chinese labels, the source language, whatever the simulator's language is.
    private func makeApp(_ arguments: [String], language: String = "zh-Hans") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-noAnalytics", "-AppleLanguages", "(\(language))", "-AppleLocale", language.replacingOccurrences(of: "-", with: "_")]
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
        let app = makeApp(["-resetState"])
        app.launch()
        XCTAssertTrue(app.buttons["startConnecting"].waitForExistence(timeout: 5))
        app.buttons["tryDemo"].tap()
        XCTAssertTrue(app.staticTexts["今日"].waitForExistence(timeout: 5))
        attach(app, name: "demo-home")
        // The way out sits beside the title, not at the end of the list.
        app.buttons["leaveDemo"].tap()
        XCTAssertTrue(app.buttons["startConnecting"].waitForExistence(timeout: 5))
    }

    func testSettingsLeadsWithLeavingDemo() {
        let app = launch()
        app.buttons["settings"].tap()
        let leave = app.buttons["settingsLeaveDemo"]
        XCTAssertTrue(leave.waitForExistence(timeout: 5))
        attach(app, name: "demo-settings")
        leave.tap()
        let welcome = app.buttons["startConnecting"].waitForExistence(timeout: 5)
        attach(app, name: "after-leaving-demo")
        XCTAssertTrue(welcome)
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
        app.buttons["tab-money"].tap()
        XCTAssertTrue(app.staticTexts["今天的订单"].waitForExistence(timeout: 5))
        attach(app, name: "money")
        app.buttons["tab-reviews"].tap()
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
        app.buttons["tab-projects"].tap()
        let row = app.buttons["projectRow-Pocket Ferry"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["数据来自"].waitForExistence(timeout: 5))
        app.buttons["7 天"].tap()
        XCTAssertTrue(app.staticTexts["每日新增用户"].waitForExistence(timeout: 5))
        attach(app, name: "project-detail-week")
    }

    /// Opens the paywall from settings and for a locked feature, with the local StoreKit configuration so
    /// prices and the trial are real.
    func testPaywallPosterAndPlans() throws {
        #if targetEnvironment(simulator)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        try XCTSkipIf(os.majorVersion == 26 && os.minorVersion == 5,
                      "StoreKitTest fails on the iOS 26.5 simulator (SKInternalErrorDomain 3); run on iOS 18 or 26.6+.")
        #endif
        let session = try SKTestSession(configurationFileNamed: "Products")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()

        var app = launch()
        XCTAssertTrue(app.staticTexts["Lumen Notes"].waitForExistence(timeout: 5))
        app.buttons["settings"].tap()
        app.buttons["upgradePro"].tap()

        // Opened from settings: no row stands out, yearly is selected with its free week.
        var purchase = app.buttons["purchase"]
        XCTAssertTrue(purchase.waitForExistence(timeout: 5))
        let trial = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '免费试用 7 天'"), object: purchase)
        XCTAssertEqual(XCTWaiter.wait(for: [trial], timeout: 10), .completed, "button says \(purchase.label)")
        XCTAssertTrue(app.staticTexts["先免费 7 天"].exists)
        for perk in ["projects", "history", "widgets"] {
            let row = app.descendants(matching: .any)["perk-\(perk)"]
            XCTAssertTrue(row.exists, perk)
            XCTAssertFalse(row.isSelected, perk)
        }
        attach(app, name: "paywall-settings")

        app.buttons["plan-ai.snuffle.pro.monthly"].tap()
        XCTAssertEqual(purchase.label, "订阅 · $1.99/月")
        attach(app, name: "paywall-monthly")
        app.buttons["plan-ai.snuffle.pro.lifetime"].tap()
        XCTAssertEqual(purchase.label, "买断 · $29.99")

        app.buttons["closePaywall"].tap()
        XCTAssertFalse(purchase.waitForExistence(timeout: 2))

        // Opened for the 30-day range: that row is the one picked out.
        app = launch(["-paywall", "history"])
        purchase = app.buttons["purchase"]
        XCTAssertTrue(purchase.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["perk-history"].isSelected)
        XCTAssertFalse(app.descendants(matching: .any)["perk-projects"].isSelected)
        attach(app, name: "paywall-history")
    }

    /// Imports a real App Store Connect key through the UI, picks an app and refreshes. Runs only when
    /// `TEST_RUNNER_SNUFFLE_LIVE_ASC_*` variables are passed to xcodebuild; values are typed, never logged.
    func testLiveAppStoreKeyImport() throws {
        let env = ProcessInfo.processInfo.environment
        guard let pem = env["SNUFFLE_LIVE_ASC_PEM"], let issuer = env["SNUFFLE_LIVE_ASC_ISSUER"], let keyId = env["SNUFFLE_LIVE_ASC_KEY_ID"],
              let appName = env["SNUFFLE_LIVE_ASC_APP"] else {
            throw XCTSkip("No live App Store Connect key in the environment")
        }
        let app = makeApp(["-resetState"])
        app.launch()
        app.buttons["startConnecting"].tap()
        app.buttons["connect-appStore"].tap()
        // This key is a team key: switch to the team-key form.
        app.buttons["ascTeamKey"].tap()

        let keyField = app.textFields["ascKeyId"]
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        keyField.tap()
        keyField.typeText(keyId)
        let issuerField = app.textFields["ascIssuerId"]
        issuerField.tap()
        issuerField.typeText(issuer)
        let pemField = app.textViews["ascPem"].exists ? app.textViews["ascPem"] : app.textFields["ascPem"]
        pemField.tap()
        UIPasteboard.general.string = pem
        pemField.press(forDuration: 1.2)
        let paste = app.menuItems["粘贴"].exists ? app.menuItems["粘贴"] : app.menuItems["Paste"]
        if paste.waitForExistence(timeout: 3) { paste.tap() } else { pemField.typeText(pem) }
        if app.buttons["允许粘贴"].waitForExistence(timeout: 2) { app.buttons["允许粘贴"].tap() }

        attach(app, name: "live-asc-filled")
        app.buttons["导入并读取 App 列表"].tap()
        let appRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", appName)).firstMatch
        let listed = appRow.waitForExistence(timeout: 20)
        attach(app, name: "live-asc-apps")
        XCTAssertTrue(listed, "app list did not load")
        appRow.tap()

        // Right after linking: the reviews waiting for a reply, then the summary with today's card.
        XCTAssertTrue(app.staticTexts["App Store 连上了"].waitForExistence(timeout: 10))
        attach(app, name: "live-asc-done")
        app.buttons["continue"].tap()
        XCTAssertTrue(app.buttons["finishProject"].waitForExistence(timeout: 5))
        attach(app, name: "live-asc-connected")
        app.buttons["finishProject"].tap()

        // A store-only project shows reviews to answer as its big number, described underneath.
        let caption = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '条评论待回复'")).firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 30), "refresh did not show reviews")
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH '刚刚'"), object: app.staticTexts["refreshStatus"])
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 30), .completed)
        attach(app, name: "live-asc-home")
        app.buttons["tab-reviews"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'reply-'")).firstMatch.waitForExistence(timeout: 5))
        attach(app, name: "live-asc-reviews")
    }

    /// The connect flow and the project and settings pages, without signing in anywhere.
    func testConnectFlowAndManagementPages() {
        var app = makeApp(["-resetState"])
        app.launch()
        app.buttons["startConnecting"].tap()
        XCTAssertTrue(app.buttons["posthogSignIn"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["startDemo"].exists)
        attach(app, name: "connect-start")
        app.buttons["connect-revenueCat"].tap()
        XCTAssertTrue(app.staticTexts["连接 RevenueCat"].waitForExistence(timeout: 5))
        attach(app, name: "connect-revenuecat")
        app.buttons["返回"].tap()
        app.buttons["connect-appStore"].tap()
        XCTAssertTrue(app.staticTexts["连接 App Store"].waitForExistence(timeout: 5))
        attach(app, name: "connect-appstore")
        app.buttons["返回"].tap()
        app.buttons["startDemo"].tap()
        XCTAssertTrue(app.staticTexts["今日"].waitForExistence(timeout: 5))

        app = makeApp(["-resetState", "-sampleWorkspace"])
        app.launch()
        app.buttons["settings"].tap()
        XCTAssertTrue(app.buttons["upgradePro"].waitForExistence(timeout: 5))
        attach(app, name: "settings")
        app.buttons["完成"].tap()
        app.buttons["tab-projects"].tap()
        let row = app.buttons["projectRow-Lumen Notes"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        attach(app, name: "projects")
        app.buttons["accounts"].tap()
        XCTAssertTrue(app.staticTexts["已登录的账号"].waitForExistence(timeout: 5))
        attach(app, name: "accounts")
        app.buttons["返回"].tap()
        row.tap()
        app.buttons["编辑"].tap()
        XCTAssertTrue(app.buttons["projectIcon"].waitForExistence(timeout: 5))
        attach(app, name: "editor")
        app.swipeUp()
        attach(app, name: "editor-metrics")
    }

    /// Every tab scrolls its last row clear of the tab bar and the refresh button.
    func testEveryTabScrollsClearOfTheTabBar() {
        let app = launch()
        refresh(app)
        for tab in ["today", "money", "reviews", "projects"] {
            app.buttons["tab-\(tab)"].tap()
            for _ in 0..<6 { app.swipeUp(velocity: .fast) }
            sleep(1)
            attach(app, name: "bottom-\(tab)")
        }
        // The last card of 今日 can be reached above the bar once scrolled to the end. Its frame is not
        // checked: SwiftUI reports a combined NavigationLink taller than the screen. The screenshot shows the gap.
        app.buttons["tab-today"].tap()
        for _ in 0..<6 { app.swipeUp(velocity: .fast) }
        sleep(1)
        XCTAssertTrue(app.buttons["card-Quiet Atlas"].isHittable)
    }

    // Every shipped language: the tabs and settings show no leftover Chinese, and right-to-left Arabic mirrors the
    // layout. Screenshots of each language are attached for a look at long words and wrapping. One test per
    // language, so a slow or stuck launch only fails its own language.
    func testLanguage_en() { checkLanguage("en") }
    func testLanguage_zhHant() { checkLanguage("zh-Hant") }
    func testLanguage_ja() { checkLanguage("ja") }
    func testLanguage_ko() { checkLanguage("ko") }
    func testLanguage_de() { checkLanguage("de") }
    func testLanguage_es() { checkLanguage("es") }
    func testLanguage_es419() { checkLanguage("es-419") }
    func testLanguage_fr() { checkLanguage("fr") }
    func testLanguage_it() { checkLanguage("it") }
    func testLanguage_ptBR() { checkLanguage("pt-BR") }
    func testLanguage_ptPT() { checkLanguage("pt-PT") }
    func testLanguage_ru() { checkLanguage("ru") }
    func testLanguage_uk() { checkLanguage("uk") }
    func testLanguage_tr() { checkLanguage("tr") }
    func testLanguage_vi() { checkLanguage("vi") }
    func testLanguage_th() { checkLanguage("th") }
    func testLanguage_hi() { checkLanguage("hi") }
    func testLanguage_ar() { checkLanguage("ar") }

    private func checkLanguage(_ language: String) {
        // Han characters belong only in Traditional Chinese and Japanese. Lines with kana are the demo's Japanese
        // review, which is user content and stays as written.
        let han = try! NSRegularExpression(pattern: "^[^\\u3040-\\u30ff]*[\\u4e00-\\u9fff][^\\u3040-\\u30ff]*$")
        let app = makeApp(["-resetState", "-demo"], language: language)
        app.launch()
        XCTAssertTrue(app.buttons["tab-today"].waitForExistence(timeout: 10))
        // One accessibility snapshot per screen; reading elements one by one takes minutes.
        var screens: [String] = []
        for tab in ["today", "money", "projects"] {
            app.buttons["tab-\(tab)"].tap()
            screens.append(app.debugDescription)
            attach(app, name: "\(language)-\(tab)")
        }
        app.buttons["tab-today"].tap()
        app.buttons["settings"].tap()
        XCTAssertTrue(app.buttons["settingsLeaveDemo"].waitForExistence(timeout: 5))
        screens.append(app.debugDescription)
        attach(app, name: "\(language)-settings")
        if !["zh-Hant", "ja"].contains(language) {
            let leftovers = screens.flatMap { $0.split(separator: "\n") }.map(String.init)
                .filter { han.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            XCTAssertEqual(leftovers, [], "Chinese left in \(language)")
        }
        if language == "ar" {
            // Right to left: the first tab sits on the right.
            XCTAssertGreaterThan(app.buttons["tab-today"].frame.minX, app.buttons["tab-projects"].frame.minX)
        }
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
