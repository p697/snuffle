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
        let orders = try await provider.orders(for: project, days: 30)
        print("[live]   orders (30 days): \(orders.count), named: \(orders.filter { $0.product != nil }.count)")
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
        let now = Date()
        let from = RevenueCatClient.utcDate(now.addingTimeInterval(-Double(SalesWindows.lookbackDays - 1) * 86_400))
        let windows = RevenueCatClient.windows(try await client.dailySales(projectId: projectId, from: from, to: RevenueCatClient.utcDate(now)), today: now)
        let overview = try await client.overview(projectId: projectId)
        print("[live]   sales \(Metric.sales.map { "\($0.id) \(windows.values[$0] ?? -1)" }), before \(windows.previous.map { "\($0.key.id) \($0.value)" }.sorted())")
        print("[live]   mrr \(overview.mrr ?? -1), active \(overview.activeSubscriptions ?? -1), 28 days \(overview.revenueLast28Days ?? -1)")
    }

    /// A Google access token with the androidpublisher and playdeveloperreporting scopes, e.g. from
    /// `gcloud auth application-default print-access-token`; such a token also needs `SNUFFLE_LIVE_GOOGLE_QUOTA_PROJECT`,
    /// a Cloud project with both APIs on.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SNUFFLE_LIVE_GOOGLE_TOKEN"] != nil))
    func googlePlayReviewsAndVitals() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        if let project = env["SNUFFLE_LIVE_GOOGLE_QUOTA_PROJECT"] { configuration.httpAdditionalHeaders = ["x-goog-user-project": project] }
        let http = HTTPClient(session: URLSession(configuration: configuration))
        let token = env["SNUFFLE_LIVE_GOOGLE_TOKEN"]!
        let client = GooglePlayClient(http: http) { token }
        let apps = try await client.apps()
        print("[live] Google Play apps: \(apps.count)")
        for app in apps {
            let reviews = try await client.reviews(packageName: app.packageName, projectId: UUID())
            let detailed = reviews.filter { $0.appVersion != nil || $0.device != nil || $0.system != nil }.count
            print("[live]   \(app.displayName): \(reviews.count) reviews this week, \(detailed) with version or device, \(reviews.filter(\.needsReply).count) to answer")
            #expect(reviews.allSatisfy { (1...5).contains($0.rating) })
            let vitals = try await client.vitals(packageName: app.packageName, metrics: [.crashRate, .anrRate])
            print("[live]   crash \(vitals[.crashRate].map { "\($0) = \(Format.rate($0))" } ?? "no data"), ANR \(vitals[.anrRate].map { "\($0) = \(Format.rate($0))" } ?? "no data")")
            #expect(vitals.values.allSatisfy { (0...1).contains($0) }, "a share of people, not a percent")
        }
        // "package/reviewId,…": whether Google still answers for a review older than a week, by its id.
        for pair in (env["SNUFFLE_LIVE_GOOGLE_OLD_REVIEWS"] ?? "").split(separator: ",") {
            let parts = pair.split(separator: "/", maxSplits: 1).map(String.init)
            var request = URLRequest(url: GooglePlayClient.base.appending(path: "\(parts[0])/reviews/\(parts[1])"))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            do {
                let body = try await http.send(request, platform: .googlePlay)
                let page = try GooglePlayParsing.reviews(Data(#"{"reviews":["#.utf8) + body + Data("]}".utf8), projectId: UUID())
                print("[live]   old review by id: found, last written \(page.reviews.first.map { "\($0.createdAt)" } ?? "?"), replied \(page.reviews.first?.reply != nil)")
            } catch {
                print("[live]   old review by id: \(error.localizedDescription)")
            }
        }
    }
}
