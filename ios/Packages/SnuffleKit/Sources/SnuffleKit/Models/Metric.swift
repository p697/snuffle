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
        case .newUsers, .activeToday, .activeWeek, .activeMonth, .newWeek, .totalUsers, .online, .pageviews, .event, .orders: .posthog
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

    /// Read at most once an hour (`hourlyInterval`): the 30-day window, and numbers the source itself only
    /// recalculates now and then. Everything else is read on every refresh.
    public var isHourly: Bool {
        switch self {
        case .activeMonth, .mrr, .activeSubscriptions, .activeTrials, .revenueLast28Days: true
        default: false
        }
    }

    public var isMoney: Bool { self == .revenue || self == .mrr || self == .revenueLast28Days }

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
    }

    /// The reference `ProjectSnapshot.previous` holds for this metric, if any.
    public var reference: Reference? {
        switch self {
        case .totalUsers: .today
        case .newUsers, .activeToday: .sameTimeYesterday
        case .activeWeek, .newWeek: .previousPeriod
        default: nil
        }
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
        }
    }

    /// The number as shown: dollars for money, whole counts otherwise.
    public func format(_ value: Double) -> String {
        isMoney ? Format.money(value) : Format.number(Int(value.rounded()))
    }
}

/// A place on a project card: a big number, a smaller one by row and position, or the empty place at the end of a
/// row that has room, where `row == rows.count` starts a new row.
public enum CardSlot: Hashable, Sendable {
    case big(Int)
    case small(row: Int, index: Int)
    case add(row: Int)
}

/// Which numbers a project card shows: one or two big ones, up to two rows of one to three smaller ones beneath, and
/// whether the last 14 days of activity and the platform split are drawn.
public struct CardLayout: Codable, Hashable, Sendable {
    public var big: [Metric]
    /// The rows of smaller numbers, top first. Never holds an empty row.
    public var rows: [[Metric]]
    /// Bars of the last 14 days' active people beside the big number.
    public var trend: Bool
    /// The share of each platform among everyone counted.
    public var split: Bool

    public static let maxBig = 2
    public static let maxRows = 2
    public static let perRow = 3
    /// Saved with every layout; layouts from builds before it are replaced by the standard one.
    static let version = 2

    /// A metric appears once: repeats are dropped, as are numbers past a row's room and rows past the last.
    public init(big: [Metric], rows: [[Metric]] = [], trend: Bool = true, split: Bool = true) {
        var seen = Set<Metric>()
        func take(_ metrics: [Metric], upTo limit: Int) -> [Metric] {
            var kept: [Metric] = []
            for metric in metrics where kept.count < limit && seen.insert(metric).inserted { kept.append(metric) }
            return kept
        }
        self.big = take(big, upTo: Self.maxBig)
        self.rows = Array(rows.map { take($0, upTo: Self.perRow) }.filter { !$0.isEmpty }.prefix(Self.maxRows))
        self.trend = trend
        self.split = split
    }

    /// The smaller numbers, row after row.
    public var small: [Metric] { rows.flatMap(\.self) }
    public var metrics: [Metric] { big + small }

    public subscript(slot: CardSlot) -> Metric? {
        switch slot {
        case .big(let index): big.indices.contains(index) ? big[index] : nil
        case .small(let row, let index): rows.indices.contains(row) && rows[row].indices.contains(index) ? rows[row][index] : nil
        case .add: nil
        }
    }

    /// Every number's place, in reading order.
    public var slots: [CardSlot] {
        big.indices.map { .big($0) } + rows.indices.flatMap { row in rows[row].indices.map { .small(row: row, index: $0) } }
    }

    /// The empty places a number can go: the end of each row with room, then a new row while there is room for one.
    public var openings: [CardSlot] {
        rows.indices.filter { rows[$0].count < Self.perRow }.map { .add(row: $0) } + (rows.count < Self.maxRows ? [.add(row: rows.count)] : [])
    }

    public func slot(of metric: Metric) -> CardSlot? {
        slots.first { self[$0] == metric }
    }

    /// `metric`, picked from the library, in `slot`. One already elsewhere on the card trades places with the number
    /// in `slot`, or moves when `slot` is empty, so nothing shows twice.
    public func placing(_ metric: Metric, at slot: CardSlot) -> CardLayout {
        if let from = self.slot(of: metric) { return moving(from: from, to: slot) ?? self }
        var copy = self
        switch slot {
        case .big, .small:
            guard self[slot] != nil else { return self }
            copy.put(metric, at: slot)
        case .add(let row):
            guard openings.contains(slot) else { return self }
            if row == rows.count { copy.rows.append([metric]) } else { copy.rows[row].append(metric) }
        }
        return copy
    }

    /// The number in `from` dropped on `to`: two numbers trade places, and one dropped on an empty place moves to
    /// the end of that row. Nil when nothing can move there, as when it would take the card's only big number.
    public func moving(from: CardSlot, to: CardSlot) -> CardLayout? {
        guard let metric = self[from] else { return nil }
        if from == to { return self }
        if let other = self[to] {
            var copy = self
            copy.put(other, at: from)
            copy.put(metric, at: to)
            return copy
        }
        guard case .add(let row) = to, openings.contains(to) else { return nil }
        var big = big
        var rows = rows
        switch from {
        case .big(let index):
            guard big.count > 1 else { return nil }
            big.remove(at: index)
        case .small(let fromRow, let index):
            rows[fromRow].remove(at: index)
        case .add:
            return nil
        }
        if row == rows.count { rows.append([metric]) } else { rows[row].append(metric) }
        return CardLayout(big: big, rows: rows, trend: trend, split: split)
    }

    /// Without the number in `slot`. The only big number stays.
    public func removing(_ slot: CardSlot) -> CardLayout {
        var big = big
        var rows = rows
        switch slot {
        case .big(let index) where big.count > 1 && big.indices.contains(index):
            big.remove(at: index)
        case .small(let row, let index) where self[slot] != nil:
            rows[row].remove(at: index)
        default:
            return self
        }
        return CardLayout(big: big, rows: rows, trend: trend, split: split)
    }

    private mutating func put(_ metric: Metric, at slot: CardSlot) {
        switch slot {
        case .big(let index): big[index] = metric
        case .small(let row, let index): rows[row][index] = metric
        case .add: break
        }
    }

    /// The layout as drawn for `project`: numbers from sources it does not have are left out, a card with no big
    /// number left promotes its first small one, and bars and split need PostHog.
    public func visible(in project: Project) -> CardLayout {
        var big = big.filter { $0.isAvailable(in: project) }
        var rows = rows.map { $0.filter { $0.isAvailable(in: project) } }.filter { !$0.isEmpty }
        if big.isEmpty, !rows.isEmpty { big = [rows[0].removeFirst()] }
        if big.isEmpty { big = CardLayout.standard(for: project).big }
        let people = project.posthog != nil
        return CardLayout(big: big, rows: rows, trend: trend && people, split: split && people)
    }

    /// The card a project starts with. With PostHog: everyone counted, with today's, the week's and the week's new
    /// people beneath; otherwise the reviews waiting for a reply, or revenue.
    public static func standard(for project: Project) -> CardLayout {
        guard project.posthog != nil else {
            return CardLayout(big: [project.hasStore ? .reviewsToAnswer : .revenue], rows: project.revenueCat != nil && project.hasStore ? [[.mrr]] : [])
        }
        return CardLayout(big: [.totalUsers], rows: [[.activeToday, .activeWeek, .newWeek]])
    }

    // Stored as metric ids so a renamed case never breaks saved layouts; unknown ids are dropped. Layouts saved
    // before rows keep their one row under `small`.
    enum CodingKeys: String, CodingKey { case big, rows, small, trend, split, v }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try container.decodeIfPresent([[String]].self, forKey: .rows)
            ?? [try container.decodeIfPresent([String].self, forKey: .small) ?? []]
        self.init(
            big: try container.decode([String].self, forKey: .big).compactMap(Metric.init(id:)),
            rows: rows.map { $0.compactMap(Metric.init(id:)) },
            trend: try container.decodeIfPresent(Bool.self, forKey: .trend) ?? true,
            split: try container.decodeIfPresent(Bool.self, forKey: .split) ?? true
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(big.map(\.id), forKey: .big)
        try container.encode(rows.map { $0.map(\.id) }, forKey: .rows)
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
