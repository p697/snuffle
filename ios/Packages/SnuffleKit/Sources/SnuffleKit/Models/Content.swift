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
    public var createdAt: Date
    public var reply: ReviewReply?

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
        reply: ReviewReply? = nil
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

/// One day in a project's history chart.
public struct DailyPoint: Codable, Hashable, Sendable, Identifiable {
    public var day: Date
    public var newUsers: Int?
    public var revenue: Double?
    public var active: Int?

    public var id: Date { day }

    public init(day: Date, newUsers: Int?, revenue: Double?, active: Int?) {
        self.day = day
        self.newUsers = newUsers
        self.revenue = revenue
        self.active = active
    }
}
