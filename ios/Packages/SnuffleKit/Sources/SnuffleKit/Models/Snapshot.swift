import Foundation

/// Everything one refresh learned about one project. A metric is missing when no connected source provides it, or
/// when nothing on screen asked for it.
public struct ProjectSnapshot: Hashable, Sendable {
    public var projectId: UUID
    public var fetchedAt: Date
    /// Start of "today" in the project's time zone when this was fetched; deltas never cross it.
    public var dayStart: Date
    public var values: [Metric: Double]
    /// What each number is set against (`Metric.reference`): the total before today, the same count yesterday up to
    /// this time of day, or the window before this one.
    public var previous: [Metric: Double]
    /// People active on each of the last 14 days, oldest first; the last is today so far.
    public var dailyActive: [Int]
    /// Everyone counted in the total, by platform, largest first.
    public var platforms: [PlatformCount]
    public var revenueSource: Platform?
    /// When the hourly metrics (`Metric.isHourly`) were last read without a failure, and which ones were read then,
    /// so one with nothing to show (Google has no vitals for a small app) waits for the hour like the rest.
    public var hourlyReadAt: Date?
    public var hourlyRead: Set<Metric>
    public var failures: [SourceFailure]
    /// When each of the project's sources was last read without a failure (`RefreshCache.land`): the time its numbers
    /// stop at while it fails.
    public var readAt: [Platform: Date]
    /// The counting and scope its numbers were read under (`MetricSettings.inEffect`). Numbers that follow them
    /// (`Metric.followsCounting`) are never carried to, or shown for, other settings. Nil in caches from before.
    public var countedAs: MetricSettings?
    /// Everyone counted up to the start of a day, so the total adds the days since instead of rescanning all history.
    public var userTally: UserTally?

    public init(
        projectId: UUID,
        fetchedAt: Date,
        dayStart: Date,
        values: [Metric: Double] = [:],
        previous: [Metric: Double] = [:],
        dailyActive: [Int] = [],
        platforms: [PlatformCount] = [],
        revenueSource: Platform? = nil,
        hourlyReadAt: Date? = nil,
        hourlyRead: Set<Metric>? = nil,
        failures: [SourceFailure] = [],
        readAt: [Platform: Date] = [:],
        countedAs: MetricSettings? = nil,
        userTally: UserTally? = nil
    ) {
        self.projectId = projectId
        self.fetchedAt = fetchedAt
        self.dayStart = dayStart
        self.values = values
        self.previous = previous
        self.dailyActive = dailyActive
        self.platforms = platforms
        self.revenueSource = revenueSource
        self.hourlyReadAt = hourlyReadAt
        self.hourlyRead = hourlyRead ?? Set(values.keys.filter(\.isHourly))
        self.failures = failures
        self.readAt = readAt
        self.countedAs = countedAs
        self.userTally = userTally
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

    /// The failure of a source `metric` is read from in `project`, when one failed: its number stops where it was.
    public func failure(of metric: Metric, in project: Project) -> SourceFailure? {
        let platforms = metric.platforms(in: project)
        return failures.first { platforms.contains($0.platform) }
    }

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
        if hourlyReadAt == nil && sameCounting {
            merged.hourlyReadAt = previous.hourlyReadAt
            merged.hourlyRead = previous.hourlyRead
        }
        if userTally == nil && sameCounting { merged.userTally = previous.userTally }
        if sameDayFailure && sameCounting {
            merged.previous = self.previous.merging(previous.previous) { mine, _ in mine }
            if dailyActive.isEmpty { merged.dailyActive = previous.dailyActive }
            if platforms.isEmpty { merged.platforms = previous.platforms }
        }
        if sameDayFailure { merged.revenueSource = revenueSource ?? previous.revenueSource }
        return merged
    }

    /// Whether a refresh at `now` should read the hourly metrics in `wanted` again.
    public func needsHourlyRead(_ wanted: Set<Metric>, at now: Date) -> Bool {
        let hourly = wanted.filter(\.isHourly)
        guard !hourly.isEmpty else { return false }
        guard let read = hourlyReadAt, now.timeIntervalSince(read) < Metric.hourlyInterval else { return true }
        return !hourly.isSubset(of: hourlyRead)
    }
}

extension ProjectSnapshot: Codable {
    enum CodingKeys: String, CodingKey {
        case projectId, fetchedAt, dayStart, values, previous, dailyActive, platforms, revenueSource, hourlyReadAt, hourlyRead, failures, readAt, countedAs, userTally
    }

    /// Values are stored by metric id. A cache from before metrics had ids reads as empty: the next refresh fills it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectId = try container.decode(UUID.self, forKey: .projectId)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        dayStart = try container.decode(Date.self, forKey: .dayStart)
        values = Self.decodeMetrics(try container.decodeIfPresent([String: Double].self, forKey: .values))
        previous = Self.decodeMetrics(try container.decodeIfPresent([String: Double].self, forKey: .previous))
        dailyActive = try container.decodeIfPresent([Int].self, forKey: .dailyActive) ?? []
        platforms = try container.decodeIfPresent([PlatformCount].self, forKey: .platforms) ?? []
        revenueSource = try container.decodeIfPresent(Platform.self, forKey: .revenueSource)
        hourlyReadAt = try container.decodeIfPresent(Date.self, forKey: .hourlyReadAt)
        // Caches from before it was recorded: the hourly numbers they hold were read.
        hourlyRead = try container.decodeIfPresent([String].self, forKey: .hourlyRead).map { Set($0.compactMap(Metric.init(id:))) }
            ?? Set(values.keys.filter(\.isHourly))
        failures = try container.decodeIfPresent([SourceFailure].self, forKey: .failures) ?? []
        readAt = Dictionary((try container.decodeIfPresent([String: Date].self, forKey: .readAt) ?? [:]).compactMap { key, date in Platform(rawValue: key).map { ($0, date) } }, uniquingKeysWith: max)
        countedAs = try container.decodeIfPresent(MetricSettings.self, forKey: .countedAs)
        userTally = (try? container.decodeIfPresent(UserTally.self, forKey: .userTally)) ?? nil
    }

    private static func decodeMetrics(_ stored: [String: Double]?) -> [Metric: Double] {
        Dictionary((stored ?? [:]).compactMap { key, value in Metric(id: key).map { ($0, value) } }, uniquingKeysWith: { first, _ in first })
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projectId, forKey: .projectId)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(dayStart, forKey: .dayStart)
        try container.encode(Dictionary(uniqueKeysWithValues: values.map { ($0.key.id, $0.value) }), forKey: .values)
        try container.encode(Dictionary(uniqueKeysWithValues: previous.map { ($0.key.id, $0.value) }), forKey: .previous)
        try container.encode(dailyActive, forKey: .dailyActive)
        try container.encode(platforms, forKey: .platforms)
        try container.encodeIfPresent(revenueSource, forKey: .revenueSource)
        try container.encodeIfPresent(hourlyReadAt, forKey: .hourlyReadAt)
        try container.encode(hourlyRead.map(\.id).sorted(), forKey: .hourlyRead)
        try container.encode(failures, forKey: .failures)
        try container.encode(Dictionary(uniqueKeysWithValues: readAt.map { ($0.key.rawValue, $0.value) }), forKey: .readAt)
        try container.encodeIfPresent(countedAs, forKey: .countedAs)
        try container.encodeIfPresent(userTally, forKey: .userTally)
    }
}

/// How many of the people counted use one platform. `name` is the platform as PostHog has it: a `Surface` raw value,
/// or the value of the project's own platform property.
public struct PlatformCount: Codable, Hashable, Sendable {
    public var name: String
    public var count: Int

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }

    /// Platforms sorted largest first, with empty names folded into one "unknown".
    public static func sorted(_ counts: [String: Int]) -> [PlatformCount] {
        var merged: [String: Int] = [:]
        for (name, count) in counts where count > 0 {
            let key = name.isEmpty || name == "null" ? "" : name
            merged[key, default: 0] += count
        }
        return merged.map { PlatformCount(name: $0.key, count: $0.value) }.sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }
}

/// Everyone a project counts who was seen before a day began (`before`, a day start in its time zone), by the
/// platform they were first seen on. Read once from the whole history, then moved forward a day at a time by the
/// people new that day.
public struct UserTally: Codable, Hashable, Sendable {
    public var byPlatform: [String: Int]
    public var before: Date

    public init(byPlatform: [String: Int], before: Date) {
        self.byPlatform = byPlatform
        self.before = before
    }

    public var people: Int { byPlatform.values.reduce(0, +) }

    /// Adds the people first seen since `before`, as of `day`.
    public func moved(adding counts: [String: Int], to day: Date) -> UserTally {
        UserTally(byPlatform: byPlatform.merging(counts, uniquingKeysWith: +), before: day)
    }

    enum CodingKeys: String, CodingKey { case byPlatform, before }

    /// Tallies from before platforms were counted are dropped, so the next refresh reads them again.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        byPlatform = try container.decode([String: Int].self, forKey: .byPlatform)
        before = try container.decode(Date.self, forKey: .before)
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
