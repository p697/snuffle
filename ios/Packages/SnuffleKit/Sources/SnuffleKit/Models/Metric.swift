import Foundation

/// A number a project card, the totals strip or a widget can show. Every one is read from a connected source; none
/// is computed from another.
public enum Metric: Hashable, Sendable {
    /// Counted the way the project's `MetricSettings.newUsers` says.
    case newUsers
    /// People with any event today, in the last 7 days and in the last 30 days.
    case activeToday, activeWeek, activeMonth
    /// People PostHog has identified (signed in), ever.
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
        .newUsers, .activeToday, .activeWeek, .activeMonth, .totalUsers, .online, .pageviews,
        .revenue, .orders, .mrr, .activeSubscriptions, .activeTrials, .revenueLast28Days,
        .reviewsToAnswer
    ]

    /// What analytics may say about a choice: the kind, never an event name the person typed.
    public var analyticsName: String {
        if case .event = self { return self == .installs ? "installs" : "event" }
        return id
    }

    // MARK: Behaviour

    public enum Source: Sendable, Equatable {
        case posthog, revenueCat, stores
        /// Today's revenue comes from whichever source the project counts it with.
        case revenueSetting
    }

    public var source: Source {
        switch self {
        case .newUsers, .activeToday, .activeWeek, .activeMonth, .totalUsers, .online, .pageviews, .event, .orders: .posthog
        case .revenue: .revenueSetting
        case .mrr, .activeSubscriptions, .activeTrials, .revenueLast28Days: .revenueCat
        case .reviewsToAnswer: .stores
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
            case .revenueSetting: false
            }
        }
    }

    /// Read at most once an hour (`hourlyInterval`): numbers over long windows, or that the source itself only
    /// recalculates now and then.
    public var isHourly: Bool {
        switch self {
        case .activeWeek, .activeMonth, .totalUsers, .mrr, .activeSubscriptions, .activeTrials, .revenueLast28Days: true
        default: false
        }
    }

    public var isMoney: Bool { self == .revenue || self == .mrr || self == .revenueLast28Days }

    /// Counted only on the surfaces the project includes (`MetricSettings.excludedSurfaces`). Event metrics, sign-up
    /// and revenue events are what they name, wherever they were sent from.
    public var isScoped: Bool {
        switch self {
        case .activeToday, .activeWeek, .activeMonth, .totalUsers, .online, .pageviews: true
        default: false
        }
    }

    /// Changes meaning when the project's counting or scope (`MetricSettings`) changes.
    public var followsCounting: Bool {
        isScoped || self == .newUsers || self == .revenue || self == .orders
    }

    /// The same everywhere, so it can be added up across projects (the totals strip and the widgets). An event is
    /// one project's own.
    public var isShared: Bool {
        if case .event = self { return false }
        return true
    }

    /// What going up means: worth celebrating, worth a mark only (a new review to answer), or nothing (people online
    /// come and go).
    public enum Rise: Sendable { case celebrate, note, ignore }

    public var rise: Rise {
        switch self {
        case .reviewsToAnswer: .note
        case .online: .ignore
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
        case .activeWeek: String(localized: "周活跃", bundle: .module)
        case .activeMonth: String(localized: "月活跃", bundle: .module)
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
        }
    }

    /// The number as shown: dollars for money, whole counts otherwise.
    public func format(_ value: Double) -> String {
        isMoney ? Format.money(value) : Format.number(Int(value.rounded()))
    }
}

/// Which numbers a project card shows: one or two big ones and up to three small pills.
public struct CardLayout: Codable, Hashable, Sendable {
    public var big: [Metric]
    public var small: [Metric]

    public static let maxBig = 2
    public static let maxSmall = 3

    /// A metric appears once: repeats, and pills that are already big, are dropped.
    public init(big: [Metric], small: [Metric] = []) {
        var seen = Set<Metric>()
        self.big = Array(big.filter { seen.insert($0).inserted }.prefix(Self.maxBig))
        self.small = Array(small.filter { seen.insert($0).inserted }.prefix(Self.maxSmall))
    }

    public var metrics: [Metric] { big + small }

    /// The layout as drawn for `project`: numbers from sources it does not have are left out, and a card with no big
    /// number left promotes its first pill.
    public func visible(in project: Project) -> CardLayout {
        var big = big.filter { $0.isAvailable(in: project) }
        var small = small.filter { $0.isAvailable(in: project) }
        if big.isEmpty, !small.isEmpty { big = [small.removeFirst()] }
        if big.isEmpty { big = CardLayout.standard(for: project).big }
        return CardLayout(big: big, small: small)
    }

    /// The card a project starts with: new users and the hourly bars when PostHog is connected, otherwise the reviews
    /// waiting for a reply; then revenue, installs and reviews as pills where the project has them.
    public static func standard(for project: Project, sendsInstalls: Bool = true) -> CardLayout {
        guard project.posthog != nil else {
            return CardLayout(big: [project.hasStore ? .reviewsToAnswer : .revenue], small: project.revenueCat != nil && project.hasStore ? [.mrr] : [])
        }
        var small: [Metric] = []
        if project.metrics.revenue != .none { small.append(.revenue) }
        if sendsInstalls { small.append(.installs) }
        if project.hasStore { small.append(.reviewsToAnswer) }
        return CardLayout(big: [.newUsers], small: small)
    }

    public static let standardTotals: [Metric] = [.newUsers, .revenue, .reviewsToAnswer]

    // Stored as metric ids so a renamed case never breaks saved layouts; unknown ids are dropped.
    enum CodingKeys: String, CodingKey { case big, small }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            big: try container.decode([String].self, forKey: .big).compactMap(Metric.init(id:)),
            small: try container.decodeIfPresent([String].self, forKey: .small)?.compactMap(Metric.init(id:)) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(big.map(\.id), forKey: .big)
        try container.encode(small.map(\.id), forKey: .small)
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
