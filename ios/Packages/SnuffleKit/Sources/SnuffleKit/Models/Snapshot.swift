import Foundation

/// Everything one refresh learned about one project. Optional fields are nil when no connected source provides them.
public struct ProjectSnapshot: Codable, Hashable, Sendable {
    public var projectId: UUID
    public var fetchedAt: Date
    /// Start of "today" in the project's time zone when this was fetched; deltas never cross it.
    public var dayStart: Date
    public var newUsers: Int?
    /// New users yesterday up to the same time of day.
    public var newUsersYesterday: Int?
    /// New users per hour of today so far, oldest first.
    public var hourlyNewUsers: [Int]
    public var online: Int?
    public var active: Int?
    public var revenue: Double?
    /// Number of orders behind `revenue`; nil when the source only reports a total (RevenueCat).
    public var sales: Int?
    public var revenueSource: Platform?
    public var extra: ExtraCount?
    public var reviewsToAnswer: Int?
    public var failures: [SourceFailure]

    public init(
        projectId: UUID,
        fetchedAt: Date,
        dayStart: Date,
        newUsers: Int? = nil,
        newUsersYesterday: Int? = nil,
        hourlyNewUsers: [Int] = [],
        online: Int? = nil,
        active: Int? = nil,
        revenue: Double? = nil,
        sales: Int? = nil,
        revenueSource: Platform? = nil,
        extra: ExtraCount? = nil,
        reviewsToAnswer: Int? = nil,
        failures: [SourceFailure] = []
    ) {
        self.projectId = projectId
        self.fetchedAt = fetchedAt
        self.dayStart = dayStart
        self.newUsers = newUsers
        self.newUsersYesterday = newUsersYesterday
        self.hourlyNewUsers = hourlyNewUsers
        self.online = online
        self.active = active
        self.revenue = revenue
        self.sales = sales
        self.revenueSource = revenueSource
        self.extra = extra
        self.reviewsToAnswer = reviewsToAnswer
        self.failures = failures
    }

    /// Keeps the last known value for anything a failed source could not refresh, so one broken source never blanks the card.
    public func fillingGaps(from previous: ProjectSnapshot?) -> ProjectSnapshot {
        guard let previous, previous.dayStart == dayStart, !failures.isEmpty else { return self }
        var merged = self
        merged.newUsers = newUsers ?? previous.newUsers
        merged.newUsersYesterday = newUsersYesterday ?? previous.newUsersYesterday
        if hourlyNewUsers.isEmpty { merged.hourlyNewUsers = previous.hourlyNewUsers }
        merged.online = online ?? previous.online
        merged.active = active ?? previous.active
        merged.revenue = revenue ?? previous.revenue
        merged.sales = sales ?? previous.sales
        merged.revenueSource = revenueSource ?? previous.revenueSource
        merged.extra = extra ?? previous.extra
        merged.reviewsToAnswer = reviewsToAnswer ?? previous.reviewsToAnswer
        return merged
    }
}

public struct ExtraCount: Codable, Hashable, Sendable {
    public var value: Int
    /// Text after the number, e.g. "次安装".
    public var label: String

    public init(value: Int, label: String) {
        self.value = value
        self.label = label
    }
}

public struct SourceFailure: Codable, Hashable, Sendable {
    public var platform: Platform
    public var message: String

    public init(platform: Platform, message: String) {
        self.platform = platform
        self.message = message
    }
}

/// What went up between two refreshes of the same day. Nothing goes up across midnight: a new day starts from its own numbers.
public struct SnapshotChange: Hashable, Sendable {
    public var newUsers: Int
    public var revenue: Double
    public var sales: Int
    /// New reviews waiting for a reply. Worth marking, but not a reason to celebrate.
    public var reviews: Int

    public static let none = SnapshotChange(newUsers: 0, revenue: 0, sales: 0)

    public var isUp: Bool { newUsers > 0 || revenue > 0.004 }
    public var hasSale: Bool { revenue > 0.004 || sales > 0 }
    public var isNews: Bool { isUp || reviews > 0 }

    public init(newUsers: Int, revenue: Double, sales: Int, reviews: Int = 0) {
        self.newUsers = newUsers
        self.revenue = revenue
        self.sales = sales
        self.reviews = reviews
    }

    public init(from old: ProjectSnapshot?, to new: ProjectSnapshot) {
        guard let old, old.dayStart == new.dayStart else {
            self = .none
            return
        }
        newUsers = max(0, (new.newUsers ?? 0) - (old.newUsers ?? 0))
        revenue = max(0, (new.revenue ?? 0) - (old.revenue ?? 0))
        sales = max(0, (new.sales ?? 0) - (old.sales ?? 0))
        reviews = max(0, (new.reviewsToAnswer ?? 0) - (old.reviewsToAnswer ?? 0))
    }
}
