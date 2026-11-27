import Foundation

/// What one refresh of one project returns. Reviews come along so the inbox never needs a second round trip.
public struct RefreshResult: Sendable {
    public var snapshot: ProjectSnapshot
    /// Each store's reviews as read this time; a store that is not connected, or could not be read, is absent.
    /// `RefreshCache.land` keeps them.
    public var reviews: [Platform: [Review]]
    /// Store ids of kept Google Play reviews that Google no longer has: their writers deleted them.
    public var deletedReviews: Set<String>
    /// The PostHog project's current time zone, so a zone changed in PostHog after connecting is picked up.
    public var posthogTimeZone: String?
    /// The surfaces to leave out, found from the project's events when none were chosen yet; the app saves them, so
    /// this is read once per project.
    public var excludedSurfaces: Set<Surface>?

    public init(snapshot: ProjectSnapshot, reviews: [Platform: [Review]] = [:], deletedReviews: Set<String> = [], posthogTimeZone: String? = nil, excludedSurfaces: Set<Surface>? = nil) {
        self.snapshot = snapshot
        self.reviews = reviews
        self.deletedReviews = deletedReviews
        self.posthogTimeZone = posthogTimeZone
        self.excludedSurfaces = excludedSurfaces
    }
}

extension DataProvider {
    /// A refresh with no reviews kept yet, as when a project is being connected.
    public func refresh(_ project: Project, metrics: Set<Metric>, previous: ProjectSnapshot?) async -> RefreshResult {
        await refresh(project, metrics: metrics, previous: previous, kept: [])
    }
}

/// The app talks to this; demo mode and live accounts are two implementations.
public protocol DataProvider: Sendable {
    /// Reads `project` for a refresh: today's numbers every time, `metrics` that are hourly only when `previous` has
    /// them older than an hour, and its reviews. `kept` are the reviews kept from earlier refreshes; a few older
    /// Google Play ones still waiting for a reply are looked up again (`Review.toLookUp`).
    func refresh(_ project: Project, metrics: Set<Metric>, previous: ProjectSnapshot?, kept: [Review]) async -> RefreshResult
    /// Reads `metrics` now, hourly ones included, to show what a choice would show before it is made.
    func measure(_ project: Project, metrics: Set<Metric>) async throws -> [Metric: Double]
    /// The project's events of the last 7 days, for choosing one to count.
    func events(for project: Project) async throws -> [EventStat]
    /// The project's surfaces with their people in the last 30 days, for choosing which to count.
    func surfaces(for project: Project) async throws -> [SurfaceStat]
    func orders(for project: Project) async throws -> [Order]
    func overview(for project: Project) async throws -> SubscriptionOverview?
    /// The project's board for the last `days` days. `total` is today's total by platform, from which the daily
    /// totals are worked back; nil leaves them out.
    func board(for project: Project, days: Int, total: [String: Int]?) async throws -> ProjectBoard
    /// The PostHog dashboards of the project.
    func dashboards(for project: Project) async throws -> [DashboardSummary]
    func dashboard(_ ref: DashboardRef, for project: Project) async throws -> DashboardDetail
    /// The counting the project's own dashboards use (`PostHogClient.dashboardCounting`).
    func dashboardCounting(for project: Project) async throws -> DashboardReading.Counting?
    /// Runs one dashboard chart's own query.
    func run(_ tile: InsightTile, for project: Project) async throws -> InsightResult
    /// How many of the last day's events `condition` keeps, out of all of them: checks a hand-typed condition.
    func check(condition: String, for project: Project) async throws -> (kept: Int, total: Int)
    func reply(to review: Review, text: String, in project: Project) async throws
}
