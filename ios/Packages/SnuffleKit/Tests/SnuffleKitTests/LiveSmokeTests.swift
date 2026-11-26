import Foundation
import Testing
@testable import SnuffleKit

/// Real-account checks with the same clients the app uses. Each one runs only when its environment variables are
/// set, and prints counts, never keys or review text. Example:
///
///     SNUFFLE_LIVE_ASC_ISSUER=… SNUFFLE_LIVE_ASC_KEY_ID=… SNUFFLE_LIVE_ASC_P8=/path/AuthKey.p8 swift test --filter LiveSmoke
@Suite("Live smoke", .serialized)
struct LiveSmokeTests {
    let env = ProcessInfo.processInfo.environment

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SNUFFLE_LIVE_ASC_P8"] != nil))
    func appStoreConnectAppsAndReviews() async throws {
        let pem = try String(contentsOfFile: env["SNUFFLE_LIVE_ASC_P8"]!, encoding: .utf8)
        let client = AppStoreConnectClient(token: try AppStoreConnectToken(issuerId: env["SNUFFLE_LIVE_ASC_ISSUER"]!, keyId: env["SNUFFLE_LIVE_ASC_KEY_ID"]!, privateKeyPEM: pem))
        let apps = try await client.apps()
        print("[live] App Store Connect apps: \(apps.count) — \(apps.map(\.name).joined(separator: ", "))")
        #expect(!apps.isEmpty)
        for app in apps {
            let reviews = try await client.reviews(appId: app.id, projectId: UUID())
            let unanswered = reviews.filter(\.needsReply).count
            let territories = Set(reviews.compactMap(\.territory)).count
            print("[live]   \(app.name): \(reviews.count) reviews, \(unanswered) to answer, \(territories) territories")
            #expect(reviews.allSatisfy { (1...5).contains($0.rating) })
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SNUFFLE_LIVE_POSTHOG_KEY"] != nil))
    func posthogRefresh() async throws {
        let account = UUID()
        let host = env["SNUFFLE_LIVE_POSTHOG_HOST"] ?? "https://us.posthog.com"
        let store = MemoryCredentialStore([account: .posthogPersonalKey(host: host, key: env["SNUFFLE_LIVE_POSTHOG_KEY"]!)])
        let tokens = TokenBroker(store: store)
        let (resolvedHost, token) = try await tokens.posthogToken(account)
        let listed = try await PostHogClient(host: resolvedHost) { token }.account()
        print("[live] PostHog projects: \(listed.projects.count)")
        let projectId = Int(env["SNUFFLE_LIVE_POSTHOG_PROJECT"] ?? "") ?? listed.projects.first!.id
        let timeZone = listed.projects.first { $0.id == projectId }?.timezone ?? "UTC"
        let project = Project(
            name: "live",
            tint: .ink,
            posthog: PostHogLink(accountId: account, projectId: projectId, projectName: "live", timeZone: timeZone),
            metrics: MetricSettings(newUsers: .event(env["SNUFFLE_LIVE_POSTHOG_SIGNUP"] ?? "user_signed_up"), revenue: .posthogEvent(event: "purchase", valueProperty: "value"))
        )
        let provider = LiveProvider(tokens: tokens)
        let everything = Set(Metric.fixed + [.installs])
        let result = await provider.refresh(project, metrics: everything, previous: nil)
        let snapshot = result.snapshot
        for metric in Metric.fixed + [.installs] where metric.isAvailable(in: project) {
            print("[live]   \(metric.id): \(snapshot[metric].map(metric.format) ?? "–")")
        }
        print("[live]   references \(snapshot.previous.map { "\($0.key.id) \(Int($0.value))" }.sorted()), days \(snapshot.dailyActive), failures \(snapshot.failures.map(\.message))")
        #expect(snapshot.failures.isEmpty)
        #expect(snapshot.hourlyReadAt != nil)
        #expect(snapshot[.activeMonth] ?? 0 >= snapshot[.activeWeek] ?? 0)
        let events = try await provider.events(for: project)
        print("[live]   events (7 days): \(events.prefix(5).map { "\($0.name) \($0.people)" })")
        #expect(snapshot.dailyActive.last == snapshot[.activeToday].map(Int.init))
        let orders = try await provider.orders(for: project)
        print("[live]   orders today: \(orders.count), named: \(orders.filter { $0.product != nil }.count)")
        let board = try await provider.board(for: project, days: 7, total: Dictionary(uniqueKeysWithValues: snapshot.platforms.map { ($0.name, $0.count) }))
        print("[live]   7-day active: \(board.days.map { $0.active.values.reduce(0, +) }), weeks \(board.weeks.count)")
        #expect(board.days.count == 7)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SNUFFLE_LIVE_RC_KEY"] != nil))
    func revenueCatRevenue() async throws {
        let client = RevenueCatClient(secretKey: env["SNUFFLE_LIVE_RC_KEY"]!)
        let projects = try await client.projects()
        print("[live] RevenueCat projects: \(projects.map(\.name))")
        let projectId = env["SNUFFLE_LIVE_RC_PROJECT"] ?? projects.first!.id
        let today = RevenueCatClient.utcDate(Date())
        let revenue = try await client.revenue(projectId: projectId, from: today, to: today)
        let overview = try await client.overview(projectId: projectId)
        print("[live]   today \(revenue), mrr \(overview.mrr ?? -1), active \(overview.activeSubscriptions ?? -1)")
    }
}
