import Foundation

/// What one refresh of one project returns. Reviews come along so the inbox never needs a second round trip.
public struct RefreshResult: Sendable {
    public var snapshot: ProjectSnapshot
    /// nil when the project has no store connected, or the store could not be read this time.
    public var reviews: [Review]?

    public init(snapshot: ProjectSnapshot, reviews: [Review]?) {
        self.snapshot = snapshot
        self.reviews = reviews
    }
}

/// The app talks to this; demo mode and live accounts are two implementations.
public protocol DataProvider: Sendable {
    func refresh(_ project: Project) async -> RefreshResult
    func orders(for project: Project) async throws -> [Order]
    func overview(for project: Project) async throws -> SubscriptionOverview?
    func history(for project: Project, days: Int) async throws -> [DailyPoint]
    func reply(to review: Review, text: String, in project: Project) async throws
}
