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
        #expect(result.snapshot.failures == [SourceFailure(platform: .revenueCat, message: "RevenueCat 拒绝了请求：Missing permission charts_metrics:overview:read")])
    }

    @Test func missingCredentialIsReportedPerSource() async {
        StubProtocol.reset([:])
        let result = await provider(store: MemoryCredentialStore()).refresh(project)
        #expect(Set(result.snapshot.failures.map(\.platform)) == [.posthog, .revenueCat])
        #expect(result.snapshot.failures.first { $0.platform == .posthog }?.message == "PostHog 还没有登录")
    }
}
