import Foundation

/// Everything one refresh learned about one project. A metric is missing when no connected source provides it, or
/// when nothing on screen asked for it.
public struct ProjectSnapshot: Hashable, Sendable {
    public var projectId: UUID
    public var fetchedAt: Date
    /// Start of "today" in the project's time zone when this was fetched; deltas never cross it.
    public var dayStart: Date
    public var values: [Metric: Double]
    /// New users yesterday up to the same time of day.
    public var newUsersYesterday: Int?
    /// New users per hour of today so far, oldest first.
    public var hourlyNewUsers: [Int]
    public var revenueSource: Platform?
    /// When the hourly metrics (`Metric.isHourly`) were last read without a failure.
    public var hourlyReadAt: Date?
    public var failures: [SourceFailure]
    /// The counting and scope its numbers were read under (`MetricSettings.inEffect`). Numbers that follow them
    /// (`Metric.followsCounting`) are never carried to, or shown for, other settings. Nil in caches from before.
    public var countedAs: MetricSettings?

    public init(
        projectId: UUID,
        fetchedAt: Date,
        dayStart: Date,
        values: [Metric: Double] = [:],
        newUsersYesterday: Int? = nil,
        hourlyNewUsers: [Int] = [],
        revenueSource: Platform? = nil,
        hourlyReadAt: Date? = nil,
        failures: [SourceFailure] = [],
        countedAs: MetricSettings? = nil
    ) {
        self.projectId = projectId
        self.fetchedAt = fetchedAt
        self.dayStart = dayStart
        self.values = values
        self.newUsersYesterday = newUsersYesterday
        self.hourlyNewUsers = hourlyNewUsers
        self.revenueSource = revenueSource
        self.hourlyReadAt = hourlyReadAt
        self.failures = failures
        self.countedAs = countedAs
    }

    public subscript(metric: Metric) -> Double? {
        get { values[metric] }
        set { values[metric] = newValue }
    }

    /// The values that mean the same under `settings`: those that follow counting only when read under it.
    public func values(countedAs settings: MetricSettings) -> [Metric: Double] {
        countedAs == settings.inEffect ? values : values.filter { !$0.key.followsCounting }
    }

    public var newUsers: Int? { values[.newUsers].map { Int($0) } }
    public var revenue: Double? { values[.revenue] }
    public var orders: Int? { values[.orders].map { Int($0) } }
    public var online: Int? { values[.online].map { Int($0) } }
    public var reviewsToAnswer: Int? { values[.reviewsToAnswer].map { Int($0) } }

    /// Fills what this refresh did not read from the previous snapshot: hourly metrics between their hourly reads,
    /// and, on the same day, anything a failed source could not refresh, so one broken source never blanks the card.
    public func fillingGaps(from previous: ProjectSnapshot?) -> ProjectSnapshot {
        guard let previous else { return self }
        var merged = self
        let sameDayFailure = previous.dayStart == dayStart && !failures.isEmpty
        // Numbers read under other counting or scope count something else: never carry them over.
        let sameCounting = previous.countedAs == countedAs
        for (metric, value) in previous.values where merged.values[metric] == nil && (metric.isHourly || sameDayFailure) && (sameCounting || !metric.followsCounting) {
            merged.values[metric] = value
        }
        if hourlyReadAt == nil && sameCounting { merged.hourlyReadAt = previous.hourlyReadAt }
        if sameDayFailure {
            merged.newUsersYesterday = newUsersYesterday ?? previous.newUsersYesterday
            if hourlyNewUsers.isEmpty { merged.hourlyNewUsers = previous.hourlyNewUsers }
            merged.revenueSource = revenueSource ?? previous.revenueSource
        }
        return merged
    }

    /// Whether a refresh at `now` should read the hourly metrics in `wanted` again.
    public func needsHourlyRead(_ wanted: Set<Metric>, at now: Date) -> Bool {
        let hourly = wanted.filter(\.isHourly)
        guard !hourly.isEmpty else { return false }
        guard let read = hourlyReadAt, now.timeIntervalSince(read) < Metric.hourlyInterval else { return true }
        return hourly.contains { values[$0] == nil }
    }
}

extension ProjectSnapshot: Codable {
    enum CodingKeys: String, CodingKey {
        case projectId, fetchedAt, dayStart, values, newUsersYesterday, hourlyNewUsers, revenueSource, hourlyReadAt, failures, countedAs
    }

    /// Values are stored by metric id. A cache from before metrics had ids reads as empty: the next refresh fills it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectId = try container.decode(UUID.self, forKey: .projectId)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        dayStart = try container.decode(Date.self, forKey: .dayStart)
        let stored = try container.decodeIfPresent([String: Double].self, forKey: .values) ?? [:]
        values = Dictionary(stored.compactMap { key, value in Metric(id: key).map { ($0, value) } }, uniquingKeysWith: { first, _ in first })
        newUsersYesterday = try container.decodeIfPresent(Int.self, forKey: .newUsersYesterday)
        hourlyNewUsers = try container.decodeIfPresent([Int].self, forKey: .hourlyNewUsers) ?? []
        revenueSource = try container.decodeIfPresent(Platform.self, forKey: .revenueSource)
        hourlyReadAt = try container.decodeIfPresent(Date.self, forKey: .hourlyReadAt)
        failures = try container.decodeIfPresent([SourceFailure].self, forKey: .failures) ?? []
        countedAs = try container.decodeIfPresent(MetricSettings.self, forKey: .countedAs)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projectId, forKey: .projectId)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(dayStart, forKey: .dayStart)
        try container.encode(Dictionary(uniqueKeysWithValues: values.map { ($0.key.id, $0.value) }), forKey: .values)
        try container.encodeIfPresent(newUsersYesterday, forKey: .newUsersYesterday)
        try container.encode(hourlyNewUsers, forKey: .hourlyNewUsers)
        try container.encodeIfPresent(revenueSource, forKey: .revenueSource)
        try container.encodeIfPresent(hourlyReadAt, forKey: .hourlyReadAt)
        try container.encode(failures, forKey: .failures)
        try container.encodeIfPresent(countedAs, forKey: .countedAs)
    }
}

public struct SourceFailure: Codable, Hashable, Sendable, LocalizedError {
    public var platform: Platform
    public var message: String
    /// Nil in caches written before kinds were recorded.
    public var kind: FailureKind?

    public init(platform: Platform, message: String, kind: FailureKind? = nil) {
        self.platform = platform
        self.message = message
        self.kind = kind
    }

    public var errorDescription: String? { message }
}

/// What went up between two refreshes of the same day. Nothing goes up across midnight: a new day starts from its own
/// numbers.
public struct SnapshotChange: Hashable, Sendable {
    /// How much each metric rose; metrics that stayed or fell are absent.
    public var rises: [Metric: Double]

    public static let none = SnapshotChange(rises: [:])

    public init(rises: [Metric: Double]) {
        self.rises = rises
    }

    /// The rises among `metrics` (what a card or the strip shows), measured from `old` to `new`.
    public init(from old: ProjectSnapshot?, to new: ProjectSnapshot, metrics: some Sequence<Metric>) {
        guard let old, old.dayStart == new.dayStart else {
            self = .none
            return
        }
        var rises: [Metric: Double] = [:]
        for metric in Set(metrics) where metric.rise != .ignore {
            guard let before = old[metric], let after = new[metric], after - before > 0.004 else { continue }
            rises[metric] = after - before
        }
        self.rises = rises
    }

    public subscript(metric: Metric) -> Double? { rises[metric] }

    /// Something good went up: worth the cat's glee.
    public var isUp: Bool { rises.keys.contains { $0.rise == .celebrate } }
    public var hasSale: Bool { rises.keys.contains(where: \.isSale) }
    /// Anything to mark, including a new review to answer.
    public var isNews: Bool { !rises.isEmpty }

    public mutating func add(_ other: SnapshotChange) {
        rises.merge(other.rises, uniquingKeysWith: +)
    }
}
