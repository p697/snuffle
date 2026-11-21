import Foundation
import Testing
@testable import SnuffleKit

/// Answers requests from a table keyed by host and path, so a whole refresh runs without the network.
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

    override func startLoading() {
        let key = (request.url?.host() ?? "") + (request.url?.path() ?? "")
        let match = Self.lock.withLock { () -> (Int, String)? in
            Self.seen.append(request)
            return Self.routes.first { key.hasPrefix($0.key) }?.value
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
            metrics: MetricSettings(newUsers: .event("user_signed_up"), revenue: .revenueCat, extra: .none)
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

    @Test func historyTakesDailyRevenueFromRevenueCatCharts() async throws {
        // The shape the Charts API really returns: one row per day and measure (0 = revenue, 1 = transactions).
        StubProtocol.reset([
            "api.revenuecat.com/v2/projects/proj1/charts/revenue": (200, #"{"object":"chart_data","measures":[{"display_name":"Revenue"},{"display_name":"Transactions"}],"values":[{"cohort":1795046400,"incomplete":false,"measure":0,"value":0},{"cohort":1795046400,"incomplete":false,"measure":1,"value":0},{"cohort":1795132800,"incomplete":false,"measure":0,"value":3.28},{"cohort":1795132800,"incomplete":false,"measure":1,"value":1},{"cohort":1795219200,"incomplete":true,"measure":0,"value":null},{"cohort":1795219200,"incomplete":true,"measure":1,"value":0}]}"#)
        ])
        var revenueOnly = project
        revenueOnly.posthog = nil
        let points = try await provider(store: store).history(for: revenueOnly, days: 3)
        let clock = ProjectClock(now: ISO8601.parse("2026-11-20T01:30:00Z")!, timeZoneIdentifier: "UTC")
        #expect(points.map { clock.dayKey($0.day) } == ["2026-11-18", "2026-11-19", "2026-11-20"])
        #expect(points.map(\.revenue) == [0, 0, 3.28], "11-19 is 0, 11-20 has the 3.28 renewal, 11-21 is outside the range")
        #expect(points.allSatisfy { $0.newUsers == nil })
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
        // 01:30 UTC: two hour columns after the two fixed ones.
        StubProtocol.reset([
            "us.posthog.com/api/projects/42/query": (200, #"{"results":[[17,5,1,2]]}"#),
            "api.revenuecat.com/v2/projects/proj1/metrics/revenue": (200, #"{"object":"revenue_metric","value":3.28}"#)
        ])
        let result = await provider(store: store).refresh(project)
        #expect(result.snapshot.newUsers == 17)
        #expect(result.snapshot.newUsersYesterday == 5)
        #expect(result.snapshot.hourlyNewUsers == [1, 2])
        #expect(result.snapshot.revenue == 3.28)
        #expect(result.snapshot.revenueSource == .revenueCat)
        #expect(result.snapshot.failures.isEmpty)
        #expect(result.reviews == nil)
        let revenueCall = try #require(StubProtocol.seen.first { $0.url?.host() == "api.revenuecat.com" })
        #expect(revenueCall.value(forHTTPHeaderField: "Authorization") == "Bearer sk_test")
        #expect(revenueCall.url?.query()?.contains("start_date=2026-11-20") == true)
    }

    @Test func oneFailingSourceDoesNotBlankTheRest() async {
        StubProtocol.reset([
            "us.posthog.com/api/projects/42/query": (200, #"{"results":[[18,5,1,3]]}"#),
            "api.revenuecat.com": (403, #"{"type":"authorization_error","message":"Missing permission charts_metrics:overview:read"}"#)
        ])
        let result = await provider(store: store).refresh(project)
        #expect(result.snapshot.newUsers == 18)
        #expect(result.snapshot.revenue == nil)
        #expect(result.snapshot.failures == [SourceFailure(platform: .revenueCat, message: "RevenueCat 拒绝了请求：Missing permission charts_metrics:overview:read", kind: .forbidden)])
    }

    @Test func missingCredentialIsReportedPerSource() async {
        StubProtocol.reset([:])
        let result = await provider(store: MemoryCredentialStore()).refresh(project)
        #expect(Set(result.snapshot.failures.map(\.platform)) == [.posthog, .revenueCat])
        #expect(result.snapshot.failures.first { $0.platform == .posthog }?.message == "PostHog 还没有登录")
    }
}
