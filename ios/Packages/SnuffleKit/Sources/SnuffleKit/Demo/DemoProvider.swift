import Foundation

/// Demo mode's data source. It keeps one `DemoWorld`, saves it after every change so the widget shows the same numbers,
/// and waits a little like a network would so the refresh animation has something to wait for.
public actor DemoProvider: DataProvider {
    private var world: DemoWorld
    private var random = SystemRandomNumberGenerator()
    private let persist: @Sendable (DemoWorld) -> Void
    private let latency: Duration

    /// `lateInDay`: see `DemoWorld.make`.
    public init(world: DemoWorld?, latency: Duration = .milliseconds(350), lateInDay: Bool = false, persist: @escaping @Sendable (DemoWorld) -> Void) {
        var random = SystemRandomNumberGenerator()
        self.world = world ?? DemoWorld.make(now: Date(), lateInDay: lateInDay, random: &random)
        self.latency = latency
        self.persist = persist
    }

    public var current: DemoWorld { world }

    public func setScenario(_ scenario: DemoWorld.Scenario) {
        world.scenario = scenario
        persist(world)
    }

    /// Today's numbers without any wait, so demo mode opens with full cards instead of dashes.
    public func seed() -> [RefreshResult] {
        DemoWorld.projects.compactMap { project in
            world.snapshot(for: project).map { RefreshResult(snapshot: $0, reviews: project.hasStore ? world.reviews.filter { $0.projectId == project.id } : nil) }
        }
    }

    /// Called once per refresh of all projects, before the per-project reads.
    public func advance() {
        world.advance(to: Date(), random: &random)
        persist(world)
    }

    public func refresh(_ project: Project, metrics: Set<Metric>, previous: ProjectSnapshot?) async -> RefreshResult {
        try? await Task.sleep(for: latency + .milliseconds(Int.random(in: 0...250)))
        guard let snapshot = world.snapshot(for: project) else {
            return RefreshResult(snapshot: ProjectSnapshot(projectId: project.id, fetchedAt: Date(), dayStart: world.dayStart), reviews: nil)
        }
        let reviews = project.hasStore ? world.reviews.filter { $0.projectId == project.id } : nil
        return RefreshResult(snapshot: snapshot, reviews: reviews)
    }

    public func measure(_ project: Project, metrics: Set<Metric>) async throws -> [Metric: Double] {
        try? await Task.sleep(for: latency)
        return world.snapshot(for: project)?.values.filter { metrics.contains($0.key) && $0.key.isAvailable(in: project) } ?? [:]
    }

    public func surfaces(for project: Project) async throws -> [SurfaceStat] {
        try? await Task.sleep(for: latency)
        return world.surfaceStats(for: project.id)
    }

    public func events(for project: Project) async throws -> [EventStat] {
        try? await Task.sleep(for: latency)
        return world.eventStats(for: project.id)
    }

    public func orders(for project: Project) async throws -> [Order] {
        world.books.first { $0.projectId == project.id && project.metrics.revenue != .revenueCat }?.orders ?? []
    }

    public func overview(for project: Project) async throws -> SubscriptionOverview? {
        guard project.revenueCat != nil else { return nil }
        return SubscriptionOverview(mrr: 87, activeSubscriptions: 47, activeTrials: 3, revenueLast28Days: 96.4)
    }

    public func history(for project: Project, days: Int) async throws -> [DailyPoint] {
        try? await Task.sleep(for: latency)
        return world.history(for: project.id, days: days)
    }

    public func reply(to review: Review, text: String, in project: Project) async throws {
        try? await Task.sleep(for: latency)
        world.markReplied(review.id, text: text, at: Date())
        persist(world)
    }
}
