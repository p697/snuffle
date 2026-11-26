import Foundation
import Testing
@testable import SnuffleKit

/// Answers requests from a table keyed by host and path, so a whole refresh runs without the network.
extension Data {
    /// A request body that URLSession handed over as a stream.
    init(reading stream: InputStream) {
        self.init()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            append(buffer, count: count)
        }
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var seen: [URLRequest] = []
    static let lock = NSLock()

    static func reset(_ routes: [String: (Int, String)]) {
        lock.withLock {
            self.routes = routes
            seen = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// The name a PostHog query was sent with, so a route can answer one query and not another.
    static func queryName(_ request: URLRequest) -> String? {
        guard let body = request.httpBodyStream.map(Data.init(reading:)) ?? request.httpBody,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return json["name"] as? String
    }

    override func startLoading() {
        let key = (request.url?.host() ?? "") + (request.url?.path() ?? "")
        let name = Self.queryName(request)
        let match = Self.lock.withLock { () -> (Int, String)? in
            Self.seen.append(request)
            // "host/path#name" answers only the query sent with that name; "host/path" answers the rest.
            let named = Self.routes.first { route in
                let parts = route.key.split(separator: "#", maxSplits: 1).map(String.init)
                return parts.count == 2 && key.hasPrefix(parts[0]) && name == parts[1]
            }
            return named?.value ?? Self.routes.first { !$0.key.contains("#") && key.hasPrefix($0.key) }?.value
        }
        let (status, body) = match ?? (404, #"{"detail":"no stub"}"#)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Live refresh", .serialized)
struct LiveProviderTests {
    let posthogAccount = UUID()
    let revenueCatAccount = UUID()

    func provider(store: MemoryCredentialStore) -> LiveProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration))
        return LiveProvider(tokens: TokenBroker(store: store, http: http), http: http) { ISO8601.parse("2026-11-20T01:30:00Z")! }
    }

    var project: Project {
        Project(
            name: "Pocket Ferry",
            tint: .coral,
            posthog: PostHogLink(accountId: posthogAccount, projectId: 42, projectName: "Ferry", timeZone: "UTC"),
            revenueCat: RevenueCatLink(accountId: revenueCatAccount, projectId: "proj1", projectName: "Ferry"),
            metrics: MetricSettings(newUsers: .event("user_signed_up"), revenue: .revenueCat)
        )
    }

    var store: MemoryCredentialStore {
        MemoryCredentialStore([
            posthogAccount: .posthogPersonalKey(host: "https://us.posthog.com", key: "phx_test"),
            revenueCatAccount: .revenueCat(secretKey: "sk_test")
        ])
    }

    @Test func listsProjectsFromEveryOrganization() async throws {
        // @me carries projects only for the current organization; the others are read separately, and one the
        // credential cannot open is skipped.
        StubProtocol.reset([
            "us.posthog.com/api/users/@me": (200, #"{"email":"me@example.com","organization":{"id":"org-a","name":"Isaac Codex","teams":[{"id":1,"name":"Isaac Codex","timezone":"UTC"}]},"organizations":[{"id":"org-a","name":"Isaac Codex"},{"id":"org-b","name":"Clawket"},{"id":"org-c","name":"Locked"}]}"#),
            "us.posthog.com/api/organizations/org-b": (200, #"{"id":"org-b","name":"Clawket","teams":[{"id":7,"name":"Clawket","timezone":"Asia/Shanghai"}],"projects":[{"id":7,"name":"Clawket","timezone":"Asia/Shanghai"}]}"#),
            "us.posthog.com/api/organizations/org-c": (403, #"{"detail":"not in scope"}"#)
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let client = PostHogClient(host: URL(string: "https://us.posthog.com")!, http: HTTPClient(session: URLSession(configuration: configuration))) { "token" }
        let account = try await client.account()
        #expect(account.email == "me@example.com")
        #expect(account.projects.map(\.name) == ["Isaac Codex", "Clawket"])
        #expect(account.projects.map(\.organizationName) == ["Isaac Codex", "Clawket"])
        #expect(account.projects.last?.timezone == "Asia/Shanghai")
        #expect(PostHogProject(id: 9, name: "Default project", timezone: nil, organizationName: "Clawket").displayName == "Clawket")
        #expect(PostHogProject(id: 9, name: "Default project", timezone: nil, organizationName: nil).displayName == "Default project")
        #expect(account.projects.first?.displayName == "Isaac Codex")
        #expect(!StubProtocol.seen.contains { $0.url?.path() == "/api/organizations/org-a/" }, "the current organization is not read twice")
    }

    @Test func boardTakesDailyRevenueFromRevenueCatCharts() async throws {
        // The shape the Charts API really returns: one row per day and measure (0 = revenue, 1 = transactions).
        StubProtocol.reset([
            "api.revenuecat.com/v2/projects/proj1/charts/revenue": (200, #"{"object":"chart_data","measures":[{"display_name":"Revenue"},{"display_name":"Transactions"}],"values":[{"cohort":1795046400,"incomplete":false,"measure":0,"value":0},{"cohort":1795046400,"incomplete":false,"measure":1,"value":0},{"cohort":1795132800,"incomplete":false,"measure":0,"value":3.28},{"cohort":1795132800,"incomplete":false,"measure":1,"value":1},{"cohort":1795219200,"incomplete":true,"measure":0,"value":null},{"cohort":1795219200,"incomplete":true,"measure":1,"value":0}]}"#)
        ])
        var revenueOnly = project
        revenueOnly.posthog = nil
        let board = try await provider(store: store).board(for: revenueOnly, days: 3, total: nil)
        let clock = ProjectClock(now: ISO8601.parse("2026-11-20T01:30:00Z")!, timeZoneIdentifier: "UTC")
        #expect(board.days.map { clock.dayKey($0.day) } == ["2026-11-18", "2026-11-19", "2026-11-20"])
        #expect(board.days.map(\.revenue) == [0, 0, 3.28], "11-19 is 0, 11-20 has the 3.28 renewal, 11-21 is outside the range")
        #expect(board.days.allSatisfy { $0.new.isEmpty && $0.active.isEmpty })
        let request = try #require(StubProtocol.seen.first?.url?.absoluteString)
        #expect(request.contains("resolution=0") && request.contains("currency=USD") && request.contains("start_date=2026-11-16"))
    }

    @Test func listsPlayAppsSoNobodyTypesAPackageName() async throws {
        StubProtocol.reset([
            "playdeveloperreporting.googleapis.com/v1beta1/apps:search": (200, #"{"apps":[{"name":"apps/com.p697.clawket","packageName":"com.p697.clawket","displayName":"Clawket"},{"name":"apps/com.example.atlas","packageName":"com.example.atlas"}]}"#)
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let client = GooglePlayClient(http: HTTPClient(session: URLSession(configuration: configuration))) { "token" }
        let apps = try await client.apps()
        #expect(apps == [
            GooglePlayApp(packageName: "com.p697.clawket", displayName: "Clawket"),
            GooglePlayApp(packageName: "com.example.atlas", displayName: "com.example.atlas")
        ], "sorted by name; a missing name falls back to the package name")
        #expect(StubProtocol.seen.first?.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(GoogleOAuth.authorizeURL(clientId: "1-a.apps.googleusercontent.com", pkce: PKCE()).absoluteString.contains("playdeveloperreporting"))
    }

    @Test func combinesSourcesIntoOneSnapshot() async throws {
        let days = (0..<14).map { String($0 * 10) }.joined(separator: ",")
        StubProtocol.reset([
            "us.posthog.com/api/projects/42/query#snuffle_counts": (200, #"{"results":[[17,5]]}"#),
            "us.posthog.com/api/projects/42/query#snuffle_people_today": (200, #"{"results":[[50,54,2,900]]}"#),
            "us.posthog.com/api/projects/42/query#snuffle_people_days": (200, #"{"results":[[531,440,\#(days)]]}"#),
            "api.revenuecat.com/v2/projects/proj1/metrics/revenue": (200, #"{"object":"revenue_metric","value":3.28}"#)
        ])
        let result = await provider(store: store).refresh(project, metrics: [.newUsers, .revenue, .activeToday, .activeWeek], previous: nil)
        #expect(result.snapshot.newUsers == 17)
        #expect(result.snapshot.hourlyReadAt == nil, "nothing hourly was asked for")
        #expect(result.snapshot.previous[.newUsers] == 5)
        #expect(result.snapshot[.activeToday] == 50 && result.snapshot.previous[.activeToday] == 54)
        #expect(result.snapshot[.activeWeek] == 531 && result.snapshot.previous[.activeWeek] == 440)
        #expect(result.snapshot.online == 2 && result.snapshot[.pageviews] == 900)
        #expect(result.snapshot.dailyActive == (0..<14).map { $0 * 10 })
        #expect(result.snapshot.revenue == 3.28)
        #expect(result.snapshot.revenueSource == .revenueCat)
        #expect(result.snapshot.failures.isEmpty)
        #expect(result.reviews == nil)
        let revenueCall = try #require(StubProtocol.seen.first { $0.url?.host() == "api.revenuecat.com" })
        #expect(revenueCall.value(forHTTPHeaderField: "Authorization") == "Bearer sk_test")
        #expect(revenueCall.url?.query()?.contains("start_date=2026-11-20") == true)
    }

    @Test func hourlyNumbersReadUnderOtherScopeAreReadAgain() async {
        StubProtocol.reset(["us.posthog.com/api/projects/42/query": (200, #"{"results":[[3,40,120,800]]}"#)])
        var scoped = project
        scoped.metrics.excludedSurfaces = [.visitors]
        let now = ISO8601.parse("2026-11-20T01:30:00Z")!
        let queries = { StubProtocol.seen.filter { $0.url?.path().contains("/query") == true }.count }
        func previous(_ countedAs: MetricSettings?) -> ProjectSnapshot {
            ProjectSnapshot(projectId: scoped.id, fetchedAt: now, dayStart: now, values: [.activeMonth: 1233], hourlyReadAt: now.addingTimeInterval(-600), countedAs: countedAs)
        }

        // Read ten minutes ago under the same scope: the monthly number is kept until the hour is up.
        let kept = await provider(store: store).refresh(scoped, metrics: [.activeMonth], previous: previous(scoped.metrics.inEffect))
        #expect(queries() == 3, "today's counts and people only")
        #expect(kept.snapshot.countedAs == scoped.metrics.inEffect)
        #expect(kept.snapshot.fillingGaps(from: previous(scoped.metrics.inEffect))[.activeMonth] == 1233)

        // Read under other scope, or before scopes were recorded: read again now, and never carried over.
        for other in [nil, scoped.metrics.leaving(out: [])] {
            StubProtocol.reset(["us.posthog.com/api/projects/42/query": (200, #"{"results":[[3,40,120,800]]}"#)])
            let reread = await provider(store: store).refresh(scoped, metrics: [.activeMonth], previous: previous(other))
            #expect(queries() == 4, "and the month")
            #expect(reread.snapshot.fillingGaps(from: previous(other))[.activeMonth] != 1233)
        }
    }

    @Test func totalUsersReadsHistoryOnceThenAddsTheNewDays() async throws {
        var scoped = project
        scoped.metrics.excludedSurfaces = [.visitors]
        let now = ISO8601.parse("2026-11-20T01:30:00Z")!
        let today = ProjectClock(now: now, timeZoneIdentifier: "UTC").todayStart
        let names = { StubProtocol.seen.compactMap(StubProtocol.queryName) }
        let firstSeen = #"{"results":[["ios",5,3,40,30],["android",2,1,20,10]]}"#

        // First time: everyone before today by platform, and the people new today on top.
        StubProtocol.reset([
            "us.posthog.com/api/projects/42/query#snuffle_tally": (200, #"{"results":[["ios",600],["android",300]]}"#),
            "us.posthog.com/api/projects/42/query#snuffle_first_seen": (200, firstSeen),
            "us.posthog.com/api/projects/42/query": (200, #"{"results":[[]]}"#)
        ])
        let first = await provider(store: store).refresh(scoped, metrics: [.totalUsers], previous: nil)
        #expect(names().contains("snuffle_tally"))
        #expect(first.snapshot.userTally == UserTally(byPlatform: ["ios": 600, "android": 300], before: today))
        #expect(first.snapshot[.totalUsers] == 907)
        #expect(first.snapshot.previous[.totalUsers] == 900, "the total set against itself before today")
        #expect(first.snapshot.platforms == [PlatformCount(name: "ios", count: 605), PlatformCount(name: "android", count: 302)])

        // Two days later: no history scan; the settled days move the tally, and today adds on top.
        let earlier = ProjectSnapshot(projectId: scoped.id, fetchedAt: now, dayStart: today, values: [.totalUsers: 1000],
                                      countedAs: scoped.metrics.inEffect,
                                      userTally: UserTally(byPlatform: ["ios": 700, "android": 300], before: today.addingTimeInterval(-2 * 86_400)))
        StubProtocol.reset([
            "us.posthog.com/api/projects/42/query#snuffle_tally_move": (200, #"{"results":[["ios",20],["android",10]]}"#),
            "us.posthog.com/api/projects/42/query#snuffle_first_seen": (200, firstSeen),
            "us.posthog.com/api/projects/42/query": (200, #"{"results":[[]]}"#)
        ])
        let next = await provider(store: store).refresh(scoped, metrics: [.totalUsers], previous: earlier)
        #expect(!names().contains("snuffle_tally"))
        #expect(next.snapshot.userTally == UserTally(byPlatform: ["ios": 720, "android": 310], before: today))
        #expect(next.snapshot[.totalUsers] == 1037)

        // Later the same day: the tally is current, so only today's first-timers are read.
        StubProtocol.reset(["us.posthog.com/api/projects/42/query#snuffle_first_seen": (200, firstSeen), "us.posthog.com/api/projects/42/query": (200, #"{"results":[[]]}"#)])
        let same = await provider(store: store).refresh(scoped, metrics: [.totalUsers], previous: next.snapshot)
        #expect(!names().contains { $0.hasPrefix("snuffle_tally") })
        #expect(same.snapshot[.totalUsers] == 1037)

        // A tally kept under another scope is not used: the history is read again.
        var other = earlier
        other.countedAs = scoped.metrics.leaving(out: [])
        StubProtocol.reset(["us.posthog.com/api/projects/42/query": (200, #"{"results":[[]]}"#)])
        _ = await provider(store: store).refresh(scoped, metrics: [.totalUsers], previous: other)
        #expect(names().contains("snuffle_tally"))
    }

    @Test func firstSeenProjectsCountNewUsersFromFirstUse() async throws {
        var seen = project
        seen.metrics = MetricSettings(newUsers: .firstSeen, revenue: .none, excludedSurfaces: [])
        StubProtocol.reset([
            "us.posthog.com/api/projects/42/query#snuffle_first_seen": (200, #"{"results":[["ios",5,3,40,30],["android",2,1,20,10]]}"#),
            "us.posthog.com/api/projects/42/query": (200, #"{"results":[[]]}"#)
        ])
        let result = await provider(store: store).refresh(seen, metrics: [.newUsers, .newWeek], previous: nil)
        #expect(result.snapshot.newUsers == 7 && result.snapshot.previous[.newUsers] == 4)
        #expect(result.snapshot[.newWeek] == 60 && result.snapshot.previous[.newWeek] == 40)
        #expect(!StubProtocol.seen.compactMap(StubProtocol.queryName).contains("snuffle_counts"), "nothing is event-based")
    }

    @Test func oneFailingSourceDoesNotBlankTheRest() async {
        StubProtocol.reset([
            "us.posthog.com/api/projects/42/query": (200, #"{"results":[[18,5,1,3]]}"#),
            "api.revenuecat.com": (403, #"{"type":"authorization_error","message":"Missing permission charts_metrics:overview:read"}"#)
        ])
        let result = await provider(store: store).refresh(project, metrics: [.newUsers, .revenue], previous: nil)
        #expect(result.snapshot.newUsers == 18)
        #expect(result.snapshot.revenue == nil)
        #expect(result.snapshot.failures == [SourceFailure(platform: .revenueCat, message: SourceError.forbidden(.revenueCat, "Missing permission charts_metrics:overview:read").localizedDescription, kind: .forbidden)])
    }

    @Test func missingCredentialIsReportedPerSource() async {
        StubProtocol.reset([:])
        let result = await provider(store: MemoryCredentialStore()).refresh(project, metrics: [.newUsers, .revenue], previous: nil)
        #expect(Set(result.snapshot.failures.map(\.platform)) == [.posthog, .revenueCat])
        #expect(result.snapshot.failures.first { $0.platform == .posthog }?.message == SourceError.missingCredential(.posthog).localizedDescription)
    }
}
