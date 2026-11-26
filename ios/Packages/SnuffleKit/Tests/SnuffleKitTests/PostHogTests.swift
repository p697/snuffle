import Foundation
import Testing
@testable import SnuffleKit

@Suite("PostHog queries")
struct PostHogTests {
    let clock = ProjectClock(now: ISO8601.parse("2026-11-20T09:32:00Z")!, timeZoneIdentifier: "UTC")

    @Test func defaultsFollowTheEventsAProjectSends() {
        let query = PostHogQueries.eventsSeen([MetricSettings.signupEvent, MetricSettings.installEvent], since: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(query == "SELECT DISTINCT event FROM events WHERE timestamp >= fromUnixTimestamp(1700000000) AND event IN ('user_signed_up', 'Application Installed')")

        let seen = PostHogParsing.eventNames([[.string("Application Installed")], [.null], []])
        #expect(seen == ["Application Installed"])

        // A project without signups counts first-seen people instead of sitting at zero.
        var project = Project(name: "p", tint: .ink, posthog: PostHogLink(accountId: UUID(), projectId: 1, projectName: "p", timeZone: "UTC"))
        project.adoptDefaults(seenEvents: seen)
        #expect(project.metrics == MetricSettings(newUsers: .firstSeen, revenue: .none))
        #expect(project.card == CardLayout(big: [.totalUsers], rows: [[.activeToday, .activeWeek, .newWeek]]))
        project.adoptDefaults(seenEvents: [MetricSettings.signupEvent, MetricSettings.installEvent])
        #expect(project.metrics == .standard)
    }

    @Test func literalsAreEscaped() {
        #expect(PostHogQueries.literal("it's") == "'it\\'s'")
        #expect(PostHogQueries.literal("a\\b") == "'a\\\\b'")
        #expect(PostHogQueries.property("plan tier") == "properties['plan tier']")
    }

    @Test func countsQueryHasNewUsersRevenueThenEvents() throws {
        let settings = MetricSettings(newUsers: .event("user_signed_up"), revenue: .posthogEvent(event: "purchase", valueProperty: "value"))
        let query = try #require(PostHogQueries.counts(settings: settings, events: [.installs, .event("paywall_viewed", people: true)], week: false, clock: clock))
        let sql = query.sql
        // New users are people, not events: someone whose signup is sent twice still counts once.
        #expect(sql.hasPrefix("SELECT uniqExactIf(person_id, event = 'user_signed_up' AND timestamp >= fromUnixTimestamp(1795132800)) AS c0, uniqExactIf(person_id, event = 'user_signed_up' AND timestamp >= fromUnixTimestamp(1795046400)"))
        #expect(sql.contains("sumIf(toFloat(properties['value']), event = 'purchase' AND timestamp >= fromUnixTimestamp(1795132800)) AS c2"))
        #expect(sql.contains("countIf(event = 'Application Installed' AND timestamp >= fromUnixTimestamp(1795132800)) AS c4"))
        #expect(sql.contains("uniqExactIf(person_id, event = 'paywall_viewed' AND timestamp >= fromUnixTimestamp(1795132800)) AS c5"))
        #expect(!sql.contains("AS c6"))
        #expect(sql.contains("WHERE timestamp >= fromUnixTimestamp(1795046400) AND event IN ('Application Installed', 'paywall_viewed', 'purchase', 'user_signed_up')"))
        #expect(query.columns == [.newToday, .newYesterday, .revenue, .orders, .metric(.installs), .metric(.event("paywall_viewed", people: true))])
        // Yesterday "by now" ends at the same wall-clock time yesterday.
        #expect(sql.contains("timestamp < fromUnixTimestamp(\(Int(clock.sameTimeYesterday.timeIntervalSince1970)))"))

        // The week's new users scan two weeks: this one and the one before.
        let week = try #require(PostHogQueries.counts(settings: settings, events: [], week: true, clock: clock))
        let start = Int(clock.historyStart(days: 14).timeIntervalSince1970)
        #expect(week.columns.prefix(4) == [.newToday, .newYesterday, .newWeek, .newWeekBefore])
        #expect(week.sql.contains("WHERE timestamp >= fromUnixTimestamp(\(start))"))
        let counts = PostHogParsing.counts([.number(17), .number(5), .number(120), .number(100), .number(940), .number(15)], columns: week.columns)
        #expect(counts.values == [.newUsers: 17, .newWeek: 120, .revenue: 940, .orders: 15])
        #expect(counts.previous == [.newUsers: 5, .newWeek: 100])
    }

    @Test func countsQueryIsSkippedWhenNothingIsEventBased() {
        let settings = MetricSettings(newUsers: .firstSeen, revenue: .revenueCat)
        #expect(PostHogQueries.counts(settings: settings, events: [], week: true, clock: clock) == nil)
    }

    /// Isaac Codex's dashboard counting: installs that opened the release app, by its own platform property.
    var isaac: MetricSettings {
        MetricSettings(
            newUsers: .firstSeen, revenue: .none, excludedSurfaces: [], activityEvent: "app_opened",
            conditions: ["properties.app_environment = 'release'", "properties.app_platform IN ('ios','android')"],
            unit: .install, platformProperty: "app_platform", since: ISO8601.parse("2026-09-01T00:00:00Z")
        )
    }

    @Test func peopleNumbersCountTheActivityEventWithinTheConditions() {
        let scope = PeopleScope(isaac, excluding: [])
        #expect(scope.unit == "distinct_id")
        #expect(scope.filter == "(properties.app_environment = 'release') AND (properties.app_platform IN ('ios','android'))")
        #expect(scope.activity == "event = 'app_opened'")
        #expect(scope.platform == "toString(properties['app_platform'])")

        let days = clock.dayStarts(days: 14).map { Int($0.timeIntervalSince1970) }
        // Today: every event of the product since yesterday; actives count the activity event, online and views any.
        let today = PostHogQueries.peopleToday(scope, clock: clock)
        #expect(today.hasSuffix("FROM events WHERE timestamp >= fromUnixTimestamp(1795046400) AND \(scope.filter!)"))
        #expect(today.contains("uniqExactIf(distinct_id, timestamp >= fromUnixTimestamp(1795132800) AND event = 'app_opened') AS active_today"))
        #expect(today.contains("uniqExactIf(distinct_id, timestamp >= now() - INTERVAL 1 MINUTE) AS online"))
        #expect(today.contains("countIf(timestamp >= fromUnixTimestamp(1795132800) AND event IN ('$pageview', '$screen')) AS views"))
        // The fortnight reads only the activity event. The 7 days are whole days counting today, as PostHog's charts
        // count them, not the last 168 hours.
        let fortnight = PostHogQueries.peopleDays(scope, clock: clock)
        #expect(fortnight.hasSuffix("FROM events WHERE timestamp >= fromUnixTimestamp(\(days[0])) AND \(scope.activeFilter!)"))
        #expect(fortnight.hasPrefix("SELECT uniqExactIf(distinct_id, timestamp >= fromUnixTimestamp(\(days[7]))) AS week, uniqExactIf(distinct_id, timestamp < fromUnixTimestamp(\(days[7]))) AS week_before"))
        #expect(fortnight.contains("AS d13"))
        #expect(!fortnight.contains("AS d14"))

        let people = PostHogParsing.people(today: [50, 54, 2, 900].map { .number($0) }, days: [531, 440].map { .number($0) } + (0..<14).map { .number(Double($0)) })
        #expect(people.values == [.activeToday: 50, .online: 2, .pageviews: 900, .activeWeek: 531])
        #expect(people.previous == [.activeToday: 54, .activeWeek: 440])
        #expect(people.daily == Array(0..<14))
    }

    @Test func firstUseIsReadFromTheCountingsFirstDayOrABoundedLookback() {
        let days = clock.dayStarts(days: 14)
        // With a first day, nobody before it counts, and nobody seen since it is new again.
        let isaacSQL = PostHogQueries.firstSeen(PeopleScope(isaac, excluding: []), clock: clock)
        #expect(isaacSQL.contains("argMin(toString(properties['app_platform']), timestamp) AS p FROM events WHERE timestamp >= fromUnixTimestamp(\(Int(isaac.since!.timeIntervalSince1970)))"))
        #expect(isaacSQL.contains("GROUP BY distinct_id) WHERE first >= fromUnixTimestamp(\(Int(days[0].timeIntervalSince1970))) GROUP BY p"))
        // Without one, 30 days before the fortnight shown.
        let standard = PostHogQueries.firstSeen(PeopleScope(.standard, excluding: [.visitors]), clock: clock)
        #expect(standard.contains("WHERE timestamp >= fromUnixTimestamp(\(Int(days[0].timeIntervalSince1970) - 30 * 86_400)) AND \(PostHogQueries.scope(excluding: [.visitors])!) GROUP BY person_id"))
        #expect(!standard.contains("persons"), "anonymous events have no person profile, so first use comes from events")

        let seen = PostHogParsing.firstSeen([
            [.string("ios"), .number(5), .number(3), .number(40), .number(30)],
            [.string("android"), .number(0), .number(1), .number(20), .number(10)]
        ])
        #expect(seen.today == 5 && seen.yesterday == 4 && seen.week == 60 && seen.weekBefore == 40)
        #expect(seen.todayByPlatform == ["ios": 5])
    }

    @Test func totalsTallyByFirstPlatformAndMoveForwardADayAtATime() {
        let scope = PeopleScope(isaac, excluding: [])
        let today = Int(clock.todayStart.timeIntervalSince1970)
        let base = PostHogQueries.tally(before: clock.todayStart, scope)
        #expect(base.contains("WHERE timestamp < fromUnixTimestamp(\(today)) AND timestamp >= fromUnixTimestamp(\(Int(isaac.since!.timeIntervalSince1970)))"))
        #expect(base.hasSuffix("GROUP BY distinct_id) GROUP BY p"))
        let since = clock.todayStart.addingTimeInterval(-2 * 86_400)
        let move = PostHogQueries.tallyMove(since: since, PeopleScope(.standard, excluding: [.visitors]), clock: clock)
        #expect(move.contains("WHERE timestamp >= fromUnixTimestamp(\(today - 367 * 86_400)) AND timestamp < fromUnixTimestamp(\(today))"))
        #expect(move.hasSuffix("WHERE first >= fromUnixTimestamp(\(today - 2 * 86_400)) GROUP BY p"))
        #expect(PostHogParsing.platformCounts([[.string("ios"), .number(600)], [.null, .number(3)], [.string("ios"), .number(1)]]) == ["ios": 601, "": 3])

        let tally = UserTally(byPlatform: ["ios": 600], before: clock.yesterdayStart).moved(adding: ["ios": 5, "android": 2], to: clock.todayStart)
        #expect(tally.people == 607 && tally.before == clock.todayStart)
        #expect(PlatformCount.sorted(["ios": 5, "android": 9, "null": 1, "web": 0]) == [PlatformCount(name: "android", count: 9), PlatformCount(name: "ios", count: 5), PlatformCount(name: "", count: 1)])
    }

    @Test func monthAndBoardQueriesFollowTheCounting() {
        let scope = PeopleScope(isaac, excluding: [])
        let month = Int(clock.historyStart(days: 30).timeIntervalSince1970)
        #expect(PostHogQueries.month(scope, clock: clock) == "SELECT uniqExact(distinct_id) FROM events WHERE timestamp >= fromUnixTimestamp(\(month)) AND \(scope.activeFilter!)")
        let shanghai = ProjectClock(now: clock.now, timeZoneIdentifier: "Asia/Shanghai")
        #expect(PostHogQueries.boardActive(scope, clock: shanghai, days: 7).hasPrefix("SELECT toString(toDate(toTimeZone(timestamp, 'Asia/Shanghai'))) AS day, toString(properties['app_platform']) AS p, uniqExact(distinct_id)"))
        #expect(PostHogQueries.boardFirstSeen(scope, clock: clock, days: 7).hasSuffix("GROUP BY day, p"))
        // Sign-ups are their event wherever they were sent from.
        #expect(!PostHogQueries.boardSignups(event: "user_signed_up", platform: scope.platform, clock: clock, days: 7).contains("app_opened"))
        let weeks = PostHogQueries.weeks(scope, clock: clock, firstWeek: clock.historyStart(days: 77), mode: 0)
        #expect(weeks.contains("toStartOfWeek(toTimeZone(timestamp, \(PostHogQueries.literal(clock.timeZone.identifier))), 0) AS week"))
        #expect(weeks.contains("min(week) OVER (PARTITION BY u) AS fw"))
        #expect(PostHogParsing.dailyByPlatform([[.string("2026-11-20"), .string("ios"), .number(3)], [.string("2026-11-20T00:00:00"), .string("android"), .number(4)]]) == ["2026-11-20": ["ios": 3, "android": 4]])
    }

    @Test func boardTotalsAreWorkedBackFromToday() {
        let totals = ProjectBoard.totals(now: ["ios": 234, "android": 819], firstSeen: [["ios": 1], ["ios": 15, "android": 42], ["ios": 4, "android": 2]])
        #expect(totals == [["ios": 215, "android": 775], ["ios": 230, "android": 817], ["ios": 234, "android": 819]])
    }

    @Test func surfacesComeFromTheSDKsOwnProperties() {
        // Signed-out web traffic is someone reading the website; apps, servers and signed-in web users are the product.
        let surface = PostHogQueries.surface
        #expect(surface.hasPrefix("multiIf(properties.$lib = 'web', if(ifNull(toString(properties.$is_identified), '') = 'true', 'web', 'visitors')"))
        #expect(surface.contains("properties.$lib IN ('posthog-ios', 'posthog-android', 'posthog-react-native', 'posthog-flutter')"))
        #expect(PostHogQueries.scope(excluding: []) == nil)
        #expect(PostHogQueries.scope(excluding: [.visitors, .other]) == "\(surface) NOT IN ('other', 'visitors')")
        let stats = PostHogParsing.surfaceStats([[.string("android"), .number(639)], [.string("visitors"), .number(422)], [.string("tv"), .number(1)]])
        #expect(stats == [SurfaceStat(surface: .android, people: 639), SurfaceStat(surface: .visitors, people: 422)])
        let events = PostHogParsing.eventStats([[.string("$set"), .number(9), .number(9)], [.string("user_signed_up"), .number(4), .number(5)]])
        #expect(events == [EventStat(name: "user_signed_up", people: 4, times: 5)])
        #expect(events.first?.looksLikeSignup == true)
    }

    @Test func visitorsAreLeftOutOnlyBesideSignedInOrAppUsers() {
        #expect(Surface.defaultExcluded(seen: [.ios, .visitors]) == [.visitors])
        #expect(Surface.defaultExcluded(seen: [.web, .visitors]) == [.visitors])
        // A website without sign-in that also sends a few server events keeps its visitors.
        #expect(Surface.defaultExcluded(seen: [.visitors, .other]) == [])
        #expect(Surface.defaultExcluded(seen: [.other]) == [])
        #expect(Surface.defaultExcluded(seen: []) == [])
        // Settings saved before counting could follow a dashboard read as Snuffle's own counting.
        let old = try! JSONDecoder().decode(MetricSettings.self, from: Data(#"{"newUsers":{"firstSeen":{}},"revenue":{"none":{}}}"#.utf8))
        #expect(old.excludedSurfaces == nil)
        #expect(old.surfacesLeftOut == [.visitors])
        #expect(old.isStandardPeople && old.unit == .person && old.conditions.isEmpty)
        let roundTrip = try! JSONDecoder().decode(MetricSettings.self, from: JSONEncoder().encode(isaac))
        #expect(roundTrip == isaac)
    }

    @Test func ordersNameTheProductFromTierAndInterval() {
        let id = UUID()
        let rows: [[JSONValue]] = [
            [.string("u1"), .string("2026-11-20T14:04:08.307000Z"), .number(300), .string("HK"),
             .null, .null, .null, .string("max"), .string("month"), .null, .null],
            [.string("u2"), .string("2026-11-20 12:55:19.722000"), .number(40), .string("null"),
             .string("Lifetime"), .null, .null, .null, .null, .null, .null],
            [.string("u3"), .string("2026-11-20T12:00:00Z"), .number(12), .string("US"),
             .null, .null, .null, .null, .null, .string("com.app.coins"), .null]
        ]
        let orders = PostHogParsing.orders(rows, projectId: id)
        #expect(orders.map(\.product) == [PostHogQueries.planName("Max", yearly: false), "Lifetime", "com.app.coins"])
        #expect(orders[0].country == "HK")
        #expect(orders[1].country == nil)
        #expect(orders[1].date == ISO8601.parse("2026-11-20T12:55:19.722Z"))
    }

    @Test func authorizeURLCarriesPKCEAndScopes() throws {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "s1")
        // RFC 7636 appendix B test vector.
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let url = PostHogOAuth.authorizeURL(region: .eu, pkce: pkce)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(url.host() == "eu.posthog.com")
        #expect(items.first { $0.name == "redirect_uri" }?.value == "https://snuffle.ai/oauth/posthog")
        #expect(items.first { $0.name == "scope" }?.value == "user:read organization:read project:read query:read dashboard:read insight:read")
        #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
    }

    @Test func callbackRejectsWrongState() throws {
        let pkce = PKCE(verifier: "v", state: "expected")
        let good = URL(string: "https://snuffle.ai/oauth/posthog?code=abc&state=expected")!
        #expect(try PostHogOAuth.code(from: good, pkce: pkce) == "abc")
        let forged = URL(string: "https://snuffle.ai/oauth/posthog?code=abc&state=other")!
        #expect(throws: SourceError.self) { try PostHogOAuth.code(from: forged, pkce: pkce) }
        let denied = URL(string: "https://snuffle.ai/oauth/posthog?error=access_denied&state=expected")!
        #expect(throws: SourceError.forbidden(.posthog, String(localized: "你取消了授权", bundle: .module))) { try PostHogOAuth.code(from: denied, pkce: pkce) }
    }
}
