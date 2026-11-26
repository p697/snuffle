import Foundation

/// A number a project card, the totals strip or a widget can show. Every one is read from a connected source; none
/// is computed from another.
public enum Metric: Hashable, Sendable, Identifiable {
    /// Counted the way the project's `MetricSettings.newUsers` says.
    case newUsers
    /// People who used the product today, and over the last 7 and 30 days counting today (whole days in the
    /// project's time zone, as PostHog's own charts count them).
    case activeToday, activeWeek, activeMonth
    /// People who started using the product in the last 7 days counting today, the way new users are counted.
    case newWeek
    /// Everyone who ever used the product (since the counting's first day).
    case totalUsers
    /// People with an event in the last minute.
    case online
    /// Pages and screens seen today: `$pageview` on the web, `$screen` in apps.
    case pageviews
    /// One PostHog event today: the people who sent it, or how many times it was sent.
    case event(String, people: Bool)
    /// Today's revenue, as the project's `MetricSettings.revenue` says.
    case revenue
    /// Today's orders behind PostHog event revenue.
    case orders
    /// RevenueCat's subscription overview.
    case mrr, activeSubscriptions, activeTrials, revenueLast28Days
    case reviewsToAnswer
    /// Google Play's Android vitals: the share of people who met a crash, or an ANR (the app not responding), while
    /// using the app, averaged over the last 28 days Google has posted, as Play Console shows them.
    case crashRate, anrRate

    /// PostHog's install event; shown as "安装" rather than by its name.
    public static let installs = Metric.event(MetricSettings.installEvent, people: false)

    /// How often a number changes: hourly ones are read at most once an hour, so a refresh stays as cheap as reading
    /// today's events.
    public static let hourlyInterval: TimeInterval = 3600

    // MARK: Identity

    /// Stable name for storage and analytics. Event metrics carry the event name after the colon.
    public var id: String {
        switch self {
        case .newUsers: "new_users"
        case .activeToday: "active_today"
        case .activeWeek: "active_week"
        case .activeMonth: "active_month"
        case .newWeek: "new_week"
        case .totalUsers: "total_users"
        case .online: "online"
        case .pageviews: "pageviews"
        case .event(let name, let people): (people ? "event_people:" : "event_count:") + name
        case .revenue: "revenue"
        case .orders: "orders"
        case .mrr: "mrr"
        case .activeSubscriptions: "active_subscriptions"
        case .activeTrials: "active_trials"
        case .revenueLast28Days: "revenue_28d"
        case .reviewsToAnswer: "reviews_to_answer"
        case .crashRate: "crash_rate"
        case .anrRate: "anr_rate"
        }
    }

    public init?(id: String) {
        if let name = id.dropPrefix("event_people:") {
            self = .event(name, people: true)
            return
        }
        if let name = id.dropPrefix("event_count:") {
            self = .event(name, people: false)
            return
        }
        guard let found = Metric.fixed.first(where: { $0.id == id }) else { return nil }
        self = found
    }

    /// Every metric except per-project events, in library order.
    public static let fixed: [Metric] = [
        .newUsers, .activeToday, .activeWeek, .activeMonth, .newWeek, .totalUsers, .online, .pageviews,
        .revenue, .orders, .mrr, .activeSubscriptions, .activeTrials, .revenueLast28Days,
        .reviewsToAnswer, .crashRate, .anrRate
    ]

    /// What analytics may say about a choice: the kind, never an event name the person typed.
    public var analyticsName: String {
        if case .event = self { return self == .installs ? "installs" : "event" }
        return id
    }

    // MARK: Behaviour

    public enum Source: Sendable, Equatable {
        case posthog, revenueCat, stores, googlePlay
        /// Today's revenue comes from whichever source the project counts it with.
        case revenueSetting
    }

    public var source: Source {
        switch self {
        case .newUsers, .activeToday, .activeWeek, .activeMonth, .newWeek, .totalUsers, .online, .pageviews, .event, .orders: .posthog
        case .revenue: .revenueSetting
        case .mrr, .activeSubscriptions, .activeTrials, .revenueLast28Days: .revenueCat
        case .reviewsToAnswer: .stores
        case .crashRate, .anrRate: .googlePlay
        }
    }

    /// Whether `project` has what this number is read from.
    public func isAvailable(in project: Project) -> Bool {
        switch self {
        case .orders: if case .posthogEvent = project.metrics.revenue { project.posthog != nil } else { false }
        case .revenue:
            switch project.metrics.revenue {
            case .posthogEvent: project.posthog != nil
            case .revenueCat: project.revenueCat != nil
            case .none: false
            }
        default:
            switch source {
            case .posthog: project.posthog != nil
            case .revenueCat: project.revenueCat != nil
            case .stores: project.hasStore
            case .googlePlay: project.googlePlay != nil
            case .revenueSetting: false
            }
        }
    }

    /// Read at most once an hour (`hourlyInterval`): the 30-day window, and numbers the source itself only
    /// recalculates now and then (Google posts vitals once a day). Everything else is read on every refresh.
    public var isHourly: Bool {
        switch self {
        case .activeMonth, .mrr, .activeSubscriptions, .activeTrials, .revenueLast28Days, .crashRate, .anrRate: true
        default: false
        }
    }

    public var isMoney: Bool { self == .revenue || self == .mrr || self == .revenueLast28Days }

    /// A share of people (0.0109 is 1.09%), shown with two decimals as Play Console does.
    public var isRate: Bool { self == .crashRate || self == .anrRate }

    /// Google Play's bad behavior threshold: above it, Play may show the app to fewer people and warn on its listing.
    public var threshold: Double? {
        switch self {
        case .crashRate: 0.0109
        case .anrRate: 0.0047
        default: nil
        }
    }

    /// Counted only on the surfaces the project includes (`MetricSettings.excludedSurfaces`). Event metrics, sign-up
    /// and revenue events are what they name, wherever they were sent from.
    public var isScoped: Bool {
        switch self {
        case .activeToday, .activeWeek, .activeMonth, .newWeek, .totalUsers, .online, .pageviews: true
        default: false
        }
    }

    /// Changes meaning when the project's counting or scope (`MetricSettings`) changes.
    public var followsCounting: Bool {
        isScoped || self == .newUsers || self == .revenue || self == .orders
    }

    /// What a number is set against, so it never stands alone.
    public enum Reference: Sendable {
        /// "今天 +6": how much of it arrived today.
        case today
        /// "昨天此时 54": the same count yesterday up to the same time of day.
        case sameTimeYesterday
        /// "▲ 20.7%": the window before this one, e.g. the 7 days before the last 7.
        case previousPeriod
        /// "阈值 1.09%": Google Play's bad behavior threshold (`threshold`), marked once the number is past it.
        case threshold
    }

    /// The reference `ProjectSnapshot.previous` holds for this metric, if any.
    public var reference: Reference? {
        switch self {
        case .totalUsers: .today
        case .newUsers, .activeToday: .sameTimeYesterday
        case .activeWeek, .newWeek: .previousPeriod
        case .crashRate, .anrRate: .threshold
        default: nil
        }
    }

    /// The same everywhere, so a card layout can carry it to every project. An event is one project's own. The widgets
    /// add their own list of these up across projects.
    public var isShared: Bool {
        if case .event = self { return false }
        return true
    }

    /// What going up means: worth celebrating, worth a mark only (a new review to answer), or nothing (people online
    /// come and go; a 28-day rate moves a little every day, and its threshold says whether that matters).
    public enum Rise: Sendable { case celebrate, note, ignore }

    public var rise: Rise {
        switch self {
        case .reviewsToAnswer: .note
        case .online, .crashRate, .anrRate: .ignore
        default: .celebrate
        }
    }

    public var isSale: Bool { self == .revenue || self == .orders }

    // MARK: Text

    /// The short name on pills, strips and widgets.
    public var title: String {
        switch self {
        case .newUsers: String(localized: "新增用户", bundle: .module)
        case .activeToday: String(localized: "今日活跃", bundle: .module)
        case .activeWeek: String(localized: "7 日活跃", bundle: .module)
        case .activeMonth: String(localized: "30 日活跃", bundle: .module)
        case .newWeek: String(localized: "7 日新增", bundle: .module)
        case .totalUsers: String(localized: "累计用户", bundle: .module)
        case .online: String(localized: "此刻在线", bundle: .module)
        case .pageviews: String(localized: "页面浏览", bundle: .module)
        case .event(let name, let people):
            if self == .installs { String(localized: "安装", bundle: .module) }
            else if people { String(localized: "\(name) 人数", bundle: .module) }
            else { name }
        case .revenue: String(localized: "收入", bundle: .module)
        case .orders: String(localized: "订单", bundle: .module)
        case .mrr: String(localized: "MRR", bundle: .module)
        case .activeSubscriptions: String(localized: "活跃订阅", bundle: .module)
        case .activeTrials: String(localized: "试用中", bundle: .module)
        case .revenueLast28Days: String(localized: "近 28 天收入", bundle: .module)
        case .reviewsToAnswer: String(localized: "待回复评论", bundle: .module)
        case .crashRate: String(localized: "崩溃率", bundle: .module)
        case .anrRate: String(localized: "ANR 率", bundle: .module)
        }
    }

    /// The number as shown: dollars for money, "0.27%" for a rate, whole counts otherwise.
    public func format(_ value: Double) -> String {
        if isMoney { return Format.money(value) }
        if isRate { return Format.rate(value) }
        return Format.number(Int(value.rounded()))
    }
}

/// Which numbers a project card shows: one or two big ones, up to three smaller ones beneath, and whether the last 14
/// days of activity and the platform split are drawn.
public struct CardLayout: Codable, Hashable, Sendable {
    public var big: [Metric]
    public var small: [Metric]
    /// Bars of the last 14 days' active people beside the big number.
    public var trend: Bool
    /// The share of each platform among everyone counted.
    public var split: Bool

    public static let maxBig = 2
    public static let maxSmall = 3
    /// Saved with every layout; layouts from builds before it are replaced by the standard one.
    static let version = 2

    /// A metric appears once: repeats, and small numbers that are already big, are dropped.
    public init(big: [Metric], small: [Metric] = [], trend: Bool = true, split: Bool = true) {
        var seen = Set<Metric>()
        self.big = Array(big.filter { seen.insert($0).inserted }.prefix(Self.maxBig))
        self.small = Array(small.filter { seen.insert($0).inserted }.prefix(Self.maxSmall))
        self.trend = trend
        self.split = split
    }

    public var metrics: [Metric] { big + small }

    /// The layout as drawn for `project`: numbers from sources it does not have are left out, a card with no big
    /// number left promotes its first small one, and bars and split need PostHog.
    public func visible(in project: Project) -> CardLayout {
        var big = big.filter { $0.isAvailable(in: project) }
        var small = small.filter { $0.isAvailable(in: project) }
        if big.isEmpty, !small.isEmpty { big = [small.removeFirst()] }
        if big.isEmpty { big = CardLayout.standard(for: project).big }
        let people = project.posthog != nil
        return CardLayout(big: big, small: small, trend: trend && people, split: split && people)
    }

    /// The card a project starts with. With PostHog: everyone counted, with today's, the week's and the week's new
    /// people beneath; otherwise the reviews waiting for a reply, or revenue.
    public static func standard(for project: Project) -> CardLayout {
        guard project.posthog != nil else {
            return CardLayout(big: [project.hasStore ? .reviewsToAnswer : .revenue], small: project.revenueCat != nil && project.hasStore ? [.mrr] : [])
        }
        return CardLayout(big: [.totalUsers], small: [.activeToday, .activeWeek, .newWeek])
    }

    // Stored as metric ids so a renamed case never breaks saved layouts; unknown ids are dropped.
    enum CodingKeys: String, CodingKey { case big, small, trend, split, v }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            big: try container.decode([String].self, forKey: .big).compactMap(Metric.init(id:)),
            small: try container.decodeIfPresent([String].self, forKey: .small)?.compactMap(Metric.init(id:)) ?? [],
            trend: try container.decodeIfPresent(Bool.self, forKey: .trend) ?? true,
            split: try container.decodeIfPresent(Bool.self, forKey: .split) ?? true
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(big.map(\.id), forKey: .big)
        try container.encode(small.map(\.id), forKey: .small)
        try container.encode(trend, forKey: .trend)
        try container.encode(split, forKey: .split)
        try container.encode(Self.version, forKey: .v)
    }

    /// Whether a saved layout comes from this version's cards.
    struct Version: Decodable {
        var v: Int?
    }
}

/// One event a project sent in the last 7 days, for picking what to count.
public struct EventStat: Hashable, Sendable, Identifiable {
    public var name: String
    public var people: Int
    public var times: Int

    public var id: String { name }

    public init(name: String, people: Int, times: Int) {
        self.name = name
        self.people = people
        self.times = times
    }

    /// Names that look like a sign-up, listed first when choosing how to count new users.
    public var looksLikeSignup: Bool {
        let lower = name.lowercased()
        return ["sign_up", "signup", "signed_up", "sign up", "signed up", "register", "account_created", "account created", "user_created"]
            .contains { lower.contains($0) }
    }

    /// PostHog's bookkeeping events, which say nothing about use.
    public static let hidden: Set<String> = ["$set", "$identify", "$groupidentify", "$create_alias", "$feature_flag_called", "$merge_dangerously", "$pageleave", "$web_vitals", "$snapshot", "$exception", "$feature_view", "$feature_interaction"]
}

extension String {
    fileprivate func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
