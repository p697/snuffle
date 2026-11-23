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

        // A project without signups counts first-seen people instead of sitting at zero, and one without installs
        // has no install pill.
        var project = Project(name: "p", tint: .ink, posthog: PostHogLink(accountId: UUID(), projectId: 1, projectName: "p", timeZone: "UTC"))
        project.adoptDefaults(seenEvents: seen)
        #expect(project.metrics == MetricSettings(newUsers: .firstSeen, revenue: .none))
        #expect(project.card == CardLayout(big: [.newUsers], small: [.installs]))
        project.adoptDefaults(seenEvents: [])
        #expect(project.card == CardLayout(big: [.newUsers]))
        project.adoptDefaults(seenEvents: [MetricSettings.signupEvent, MetricSettings.installEvent])
        #expect(project.metrics == .standard)
    }

    @Test func literalsAreEscaped() {
        #expect(PostHogQueries.literal("it's") == "'it\\'s'")
        #expect(PostHogQueries.literal("a\\b") == "'a\\\\b'")
        #expect(PostHogQueries.property("plan tier") == "properties['plan tier']")
    }

    @Test func countsQueryHasFixedColumnsThenEventsThenOneColumnPerHour() throws {
        let settings = MetricSettings(newUsers: .event("user_signed_up"), revenue: .posthogEvent(event: "purchase", valueProperty: "value"))
        let query = try #require(PostHogQueries.counts(settings: settings, events: [.installs, .event("paywall_viewed", people: true)], clock: clock))
        let sql = query.sql
        // New users are people, not events: someone whose signup is sent twice still counts once.
        #expect(sql.hasPrefix("SELECT uniqExactIf(person_id, event = 'user_signed_up' AND timestamp >= fromUnixTimestamp(1795132800)) AS c0, uniqExactIf(person_id, event = 'user_signed_up' AND timestamp >= fromUnixTimestamp(1795046400)"))
        #expect(sql.contains("sumIf(toFloat(properties['value']), event = 'purchase' AND timestamp >= fromUnixTimestamp(1795132800)) AS c2"))
        #expect(sql.contains("countIf(event = 'Application Installed' AND timestamp >= fromUnixTimestamp(1795132800)) AS c4"))
        #expect(sql.contains("uniqExactIf(person_id, event = 'paywall_viewed' AND timestamp >= fromUnixTimestamp(1795132800)) AS c5"))
        #expect(sql.contains("uniqExactIf(person_id, event = 'user_signed_up' AND timestamp >= fromUnixTimestamp(1795132800) AND timestamp < fromUnixTimestamp(1795136400)) AS c6"))
        #expect(sql.contains("AS c15"))
        #expect(!sql.contains("AS c16"))
        #expect(sql.contains("event IN ('Application Installed', 'paywall_viewed', 'purchase', 'user_signed_up')"))
        #expect(query.columns.prefix(6) == [.newToday, .newYesterday, .revenue, .orders, .metric(.installs), .metric(.event("paywall_viewed", people: true))])
        #expect(query.columns.filter { $0 == .hour }.count == 10)
        // Yesterday "by now" ends at the same wall-clock time yesterday.
        #expect(sql.contains("timestamp < fromUnixTimestamp(\(Int(clock.sameTimeYesterday.timeIntervalSince1970)))"))
    }

    @Test func countsQueryIsSkippedWhenNothingIsEventBased() {
        let settings = MetricSettings(newUsers: .firstSeen, revenue: .revenueCat)
        #expect(PostHogQueries.counts(settings: settings, events: [], clock: clock) == nil)
    }

    @Test func hourlyQueriesScanOnlyTheWindowAsked() {
        let week = Int(clock.now.timeIntervalSince1970) - 7 * 86_400
        let month = Int(clock.now.timeIntervalSince1970) - 30 * 86_400
        #expect(PostHogQueries.activity(clock: clock, month: false, excluding: []) == "SELECT uniq(person_id) AS week FROM events WHERE timestamp >= fromUnixTimestamp(\(week))")
        #expect(PostHogQueries.activity(clock: clock, month: true, excluding: []).hasSuffix("FROM events WHERE timestamp >= fromUnixTimestamp(\(month))"))
        #expect(PostHogQueries.totalUsers.hasSuffix("FROM persons WHERE is_identified = 1"))
        let stats = PostHogParsing.eventStats([[.string("$set"), .number(9), .number(9)], [.string("user_signed_up"), .number(4), .number(5)]])
        #expect(stats == [EventStat(name: "user_signed_up", people: 4, times: 5)])
        #expect(stats.first?.looksLikeSignup == true)
        #expect(PostHogQueries.presence(clock: clock, excluding: []).contains("countIf(event IN ('$pageview', '$screen'))"))
    }

    @Test func firstSeenComesFromEventsWithinABoundedLookback() {
        // Anonymous events have no person profile, so new people are counted from their first event, and only
        // the last 30 days (plus the days shown) are scanned.
        let sql = PostHogQueries.firstSeen(clock: clock, excluding: [])
        let lookback = Int(clock.yesterdayStart.timeIntervalSince1970) - 30 * 86_400
        #expect(!sql.contains("persons"))
        #expect(sql.contains("FROM events WHERE timestamp >= fromUnixTimestamp(\(lookback)) GROUP BY person_id"))
        #expect(sql.contains("countIf(first >= fromUnixTimestamp(\(Int(clock.todayStart.timeIntervalSince1970)))) AS new_today"))
        #expect(sql.contains("countIf(first >= fromUnixTimestamp(1795132800) AND first < fromUnixTimestamp(1795136400)) AS h0"))

        let history = PostHogQueries.firstSeenHistory(clock: clock, days: 7, excluding: [])
        let start = Int(clock.historyStart(days: 7).timeIntervalSince1970)
        #expect(history.contains("timestamp >= fromUnixTimestamp(\(start - 30 * 86_400))"))
        #expect(history.hasSuffix("WHERE first >= fromUnixTimestamp(\(start)) GROUP BY day ORDER BY day"))
    }

    @Test func surfacesComeFromTheSDKsOwnProperties() {
        // Signed-out web traffic is someone reading the website; apps, servers and signed-in web users are the product.
        let surface = PostHogQueries.surface
        #expect(surface.hasPrefix("multiIf(properties.$lib = 'web', if(ifNull(toString(properties.$is_identified), '') = 'true', 'web', 'visitors')"))
        #expect(surface.contains("properties.$lib IN ('posthog-ios', 'posthog-android', 'posthog-react-native', 'posthog-flutter')"))
        #expect(surface.contains("multiIf(properties.$os IN ('iOS', 'iPadOS'), 'ios', properties.$os = 'Android', 'android', 'other')"))
        #expect(PostHogQueries.scope(excluding: []) == nil)
        #expect(PostHogQueries.scope(excluding: [.visitors, .other]) == "\(surface) NOT IN ('other', 'visitors')")
        let stats = PostHogParsing.surfaceStats([[.string("android"), .number(639)], [.string("visitors"), .number(422)], [.string("tv"), .number(1)]])
        #expect(stats == [SurfaceStat(surface: .android, people: 639), SurfaceStat(surface: .visitors, people: 422)])
    }

    @Test func peopleNumbersFollowTheProjectsScope() {
        let scope = " AND \(PostHogQueries.scope(excluding: [.visitors])!)"
        #expect(PostHogQueries.presence(clock: clock, excluding: [.visitors]).hasSuffix(scope))
        #expect(PostHogQueries.activity(clock: clock, month: true, excluding: [.visitors]).hasSuffix(scope))
        #expect(PostHogQueries.firstSeen(clock: clock, excluding: [.visitors]).contains("\(scope) GROUP BY person_id"))
        #expect(PostHogQueries.firstSeenHistory(clock: clock, days: 7, excluding: [.visitors]).contains("\(scope) GROUP BY person_id"))
        // Sign-ups and revenue are their events wherever they came from; only the active column follows the scope.
        let metrics = MetricSettings(newUsers: .event("user_signed_up"), revenue: .none, excludedSurfaces: [.visitors])
        let history = PostHogQueries.history(metrics: metrics, clock: clock, days: 7)
        #expect(history.contains("uniqIf(person_id, \(PostHogQueries.scope(excluding: [.visitors])!))"))
        #expect(history.contains("uniqExactIf(person_id, event = 'user_signed_up') AS new_users"))
    }

    @Test func visitorsAreLeftOutUnlessTheyAreAllThereIs() {
        #expect(Surface.defaultExcluded(seen: [.ios, .visitors]) == [.visitors])
        #expect(Surface.defaultExcluded(seen: [.other]) == [.visitors])
        #expect(Surface.defaultExcluded(seen: [.visitors]) == [])
        #expect(Surface.defaultExcluded(seen: []) == [])
        // Projects saved before scopes existed decode with no choice yet, and leave visitors out meanwhile.
        let old = try! JSONDecoder().decode(MetricSettings.self, from: Data(#"{"newUsers":{"firstSeen":{}},"revenue":{"none":{}}}"#.utf8))
        #expect(old.excludedSurfaces == nil)
        #expect(old.surfacesLeftOut == [.visitors])
    }

    @Test func historyDaysFollowTheProjectZone() {
        let shanghai = ProjectClock(now: clock.now, timeZoneIdentifier: "Asia/Shanghai")
        let metrics = MetricSettings(newUsers: .event("user_signed_up"), revenue: .none)
        let sql = PostHogQueries.history(metrics: metrics, clock: shanghai, days: 7)
        #expect(sql.hasPrefix("SELECT toString(toDate(toTimeZone(timestamp, 'Asia/Shanghai'))) AS day"))
        #expect(sql.contains("uniqExactIf(person_id, event = 'user_signed_up') AS new_users"))
        #expect(PostHogQueries.firstSeenHistory(clock: shanghai, days: 7, excluding: []).hasPrefix("SELECT toString(toDate(toTimeZone(first, 'Asia/Shanghai'))) AS day"))
    }

    @Test func parsesCountsByColumn() throws {
        let settings = MetricSettings(newUsers: .event("user_signed_up"), revenue: .posthogEvent(event: "purchase", valueProperty: "value"))
        let query = try #require(PostHogQueries.counts(settings: settings, events: [.installs], clock: ProjectClock(now: ISO8601.parse("2026-11-20T02:10:00Z")!, timeZoneIdentifier: "UTC")))
        let row: [JSONValue] = [.number(3406), .number(2851), .number(940), .number(15), .number(557), .number(3), .number(0), .number(7)]
        let counts = PostHogParsing.counts(row, columns: query.columns)
        #expect(counts.values == [.newUsers: 3406, .revenue: 940, .orders: 15, .installs: 557])
        #expect(counts.newYesterday == 2851)
        #expect(counts.hourly == [3, 0, 7])
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

    @Test func historyFillsMissingDays() {
        let rows: [[JSONValue]] = [
            [.string("2026-11-18"), .number(100), .number(10), .number(40)],
            [.string("2026-11-20"), .number(120), .number(12), .number(0)]
        ]
        let points = PostHogParsing.history(rows, firstSeen: nil, clock: clock, days: 3, hasRevenue: true)
        #expect(points.map(\.newUsers) == [10, 0, 12])
        #expect(points.map(\.revenue) == [40, 0, 0])
        #expect(points.map(\.active) == [100, 0, 120])
    }

    @Test func historyUsesFirstSeenRowsWhenCountingThatWay() {
        let rows: [[JSONValue]] = [[.string("2026-11-20"), .number(9), .number(0), .number(0)]]
        let firstSeen: [[JSONValue]] = [[.string("2026-11-20"), .number(4)]]
        let points = PostHogParsing.history(rows, firstSeen: firstSeen, clock: clock, days: 2, hasRevenue: false)
        #expect(points.map(\.newUsers) == [0, 4])
        #expect(points.allSatisfy { $0.revenue == nil })
    }

    @Test func authorizeURLCarriesPKCEAndScopes() throws {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "s1")
        // RFC 7636 appendix B test vector.
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let url = PostHogOAuth.authorizeURL(region: .eu, pkce: pkce)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(url.host() == "eu.posthog.com")
        #expect(items.first { $0.name == "redirect_uri" }?.value == "ai.snuffle.app:/oauth/posthog")
        #expect(items.first { $0.name == "scope" }?.value == "user:read organization:read project:read query:read")
        #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
    }

    @Test func callbackRejectsWrongState() throws {
        let pkce = PKCE(verifier: "v", state: "expected")
        let good = URL(string: "ai.snuffle.app:/oauth/posthog?code=abc&state=expected")!
        #expect(try PostHogOAuth.code(from: good, pkce: pkce) == "abc")
        let forged = URL(string: "ai.snuffle.app:/oauth/posthog?code=abc&state=other")!
        #expect(throws: SourceError.self) { try PostHogOAuth.code(from: forged, pkce: pkce) }
        let denied = URL(string: "ai.snuffle.app:/oauth/posthog?error=access_denied&state=expected")!
        #expect(throws: SourceError.forbidden(.posthog, String(localized: "你取消了授权", bundle: .module))) { try PostHogOAuth.code(from: denied, pkce: pkce) }
    }
}
