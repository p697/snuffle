import Foundation

/// A store review from the App Store or Google Play.
public struct Review: Codable, Identifiable, Hashable, Sendable {
    /// Unique across stores: "<platform>:<store id>".
    public var id: String { "\(platform.rawValue):\(storeId)" }
    public var storeId: String
    public var platform: Platform
    public var projectId: UUID
    public var rating: Int
    public var title: String?
    public var body: String
    public var author: String?
    /// App Store territory (ISO 3166 alpha-3, e.g. "UKR") or nil.
    public var territory: String?
    /// Google Play reviewer language (BCP 47, e.g. "uk_UA") or nil.
    public var language: String?
    /// When Google Play last saw the review written or edited; App Store's creation date.
    public var createdAt: Date
    public var reply: ReviewReply?
    /// Google Play only: the app version and phone it was written on ("Samsung Galaxy S23", "Android 14"), and how
    /// many people found it helpful.
    public var appVersion: String?
    public var device: String?
    public var system: String?
    public var helpful: Int?

    public init(
        storeId: String,
        platform: Platform,
        projectId: UUID,
        rating: Int,
        title: String? = nil,
        body: String,
        author: String? = nil,
        territory: String? = nil,
        language: String? = nil,
        createdAt: Date,
        reply: ReviewReply? = nil,
        appVersion: String? = nil,
        device: String? = nil,
        system: String? = nil,
        helpful: Int? = nil
    ) {
        self.storeId = storeId
        self.platform = platform
        self.projectId = projectId
        self.rating = rating
        self.title = title
        self.body = body
        self.author = author
        self.territory = territory
        self.language = language
        self.createdAt = createdAt
        self.reply = reply
        self.appVersion = appVersion
        self.device = device
        self.system = system
        self.helpful = helpful
    }

    public var needsReply: Bool { reply == nil }
}

public struct ReviewReply: Codable, Hashable, Sendable {
    public var text: String
    public var date: Date?
    /// App Store holds new replies for review before they appear publicly.
    public var pending: Bool

    public init(text: String, date: Date?, pending: Bool) {
        self.text = text
        self.date = date
        self.pending = pending
    }
}

/// One paid order, read from a PostHog revenue event.
public struct Order: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var projectId: UUID
    public var date: Date
    public var amount: Double
    public var product: String?
    /// ISO 3166 alpha-2 country code when PostHog knows it.
    public var country: String?

    public init(id: String, projectId: UUID, date: Date, amount: Double, product: String?, country: String?) {
        self.id = id
        self.projectId = projectId
        self.date = date
        self.amount = amount
        self.product = product
        self.country = country
    }
}

/// RevenueCat's subscription overview for a project.
public struct SubscriptionOverview: Codable, Hashable, Sendable {
    public var mrr: Double?
    public var activeSubscriptions: Int?
    public var activeTrials: Int?
    public var revenueLast28Days: Double?

    public init(mrr: Double?, activeSubscriptions: Int?, activeTrials: Int?, revenueLast28Days: Double?) {
        self.mrr = mrr
        self.activeSubscriptions = activeSubscriptions
        self.activeTrials = activeTrials
        self.revenueLast28Days = revenueLast28Days
    }
}

/// A project's history for its board: each day by platform, and each week's new and returning people.
public struct ProjectBoard: Hashable, Sendable {
    public struct Day: Hashable, Sendable, Identifiable {
        public var day: Date
        /// People active that day, by platform.
        public var active: [String: Int]
        /// People new that day the way the project counts new users, by platform.
        public var new: [String: Int]
        /// Everyone counted at the end of the day (so far, today), by platform; empty when the total is unknown.
        public var total: [String: Int]
        public var revenue: Double?

        public var id: Date { day }

        public init(day: Date, active: [String: Int] = [:], new: [String: Int] = [:], total: [String: Int] = [:], revenue: Double? = nil) {
            self.day = day
            self.active = active
            self.new = new
            self.total = total
            self.revenue = revenue
        }
    }

    public struct Week: Hashable, Sendable, Identifiable {
        public var start: Date
        public var new: Int
        public var returning: Int

        public var id: Date { start }

        public init(start: Date, new: Int, returning: Int) {
            self.start = start
            self.new = new
            self.returning = returning
        }
    }

    public var days: [Day]
    public var weeks: [Week]
    /// Platform names in the order charts stack them: the largest first.
    public var platforms: [String]

    public init(days: [Day], weeks: [Week], platforms: [String]) {
        self.days = days
        self.weeks = weeks
        self.platforms = platforms
    }

    public var hasRevenue: Bool { days.contains { $0.revenue != nil } }

    /// The total at the end of each day, worked back from `now` (today's total by platform) by taking away the people
    /// first seen after it.
    public static func totals(now: [String: Int], firstSeen: [[String: Int]]) -> [[String: Int]] {
        var running = now
        var result = Array(repeating: [String: Int](), count: firstSeen.count)
        for index in firstSeen.indices.reversed() {
            result[index] = running
            for (platform, count) in firstSeen[index] { running[platform, default: 0] -= count }
        }
        return result
    }

    /// Platforms by their share of `counts`, largest first.
    public static func order(_ counts: [String: Int]) -> [String] {
        PlatformCount.sorted(counts).map(\.name)
    }
}
