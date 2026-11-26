import Foundation

/// Who a project's people numbers count, as HogQL pieces: one unit per person or installation, the events that belong
/// to the product, the event that means someone used it, and how platforms are named.
public struct PeopleScope: Sendable, Equatable {
    /// `person_id` or `distinct_id`.
    public var unit: String
    /// Surfaces and conditions: which events belong to the product at all. Nil keeps every event.
    public var filter: String?
    /// The condition that makes an event count as using the product; nil counts any event.
    public var activity: String?
    /// A string expression naming each event's platform.
    public var platform: String
    /// The first day totals and first-seen people count from.
    public var since: Date?

    public init(_ settings: MetricSettings, excluding excluded: Set<Surface>) {
        unit = settings.unit == .install ? "distinct_id" : "person_id"
        let parts = [PostHogQueries.scope(excluding: excluded)].compactMap { $0 } + settings.conditions.map { "(\($0))" }
        filter = parts.isEmpty ? nil : parts.joined(separator: " AND ")
        activity = settings.activityEvent.map { "event = \(PostHogQueries.literal($0))" }
        platform = settings.platformProperty.map { "toString(\(PostHogQueries.property($0)))" } ?? PostHogQueries.surface
        since = settings.since
    }

    /// Events that count as using the product.
    var activeFilter: String? {
        let parts = [filter, activity].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " AND ")
    }

    /// Where a first-seen scan starts for numbers from `start` on: `lookbackDays` earlier, so someone back after a
    /// short break is not new again, or from the counting's first day, at most half a year back.
    func lookback(from start: Date, days: Int = PostHogQueries.firstSeenLookbackDays) -> Date {
        if let since { return max(since, start.addingTimeInterval(-180 * 86_400)) }
        return start.addingTimeInterval(-Double(days) * 86_400)
    }
}

/// HogQL for every number Snuffle shows. Kept separate from the transport so tests can check the SQL itself. Every
/// timestamp is passed as Unix seconds, so "today" is decided by `ProjectClock`, not by the server's zone; people are
/// counted exactly (`uniqExact`), as PostHog's own charts count them.
public enum PostHogQueries {
    /// Escapes a value for a single-quoted HogQL string literal.
    public static func literal(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// A property reference that works for any name, including ones with spaces or `$`.
    public static func property(_ name: String) -> String {
        "properties[\(literal(name))]"
    }

    static func seconds(_ date: Date) -> Int { Int(date.timeIntervalSince1970.rounded(.down)) }

    static func at(_ date: Date) -> String { "fromUnixTimestamp(\(seconds(date)))" }

    static func and(_ condition: String?) -> String { condition.map { " AND \($0)" } ?? "" }

    /// The day an event falls on in the project's zone, as "yyyy-MM-dd", so history days match `ProjectClock`
    /// even if PostHog's own project zone has since changed.
    static func day(_ column: String, clock: ProjectClock) -> String {
        "toString(toDate(toTimeZone(\(column), \(literal(clock.timeZone.identifier)))))"
    }

    /// How far back a person must be unseen to count as new, when the counting has no first day.
    public static let firstSeenLookbackDays = 30
    /// How far back a person must be unseen to be added to the total once their first day is over.
    public static let tallyLookbackDays = 365
    /// Days of activity a card draws, and the scan every refresh makes for its people numbers.
    public static let recentDays = 14

    // MARK: Surfaces

    static let mobileLibraries = ["posthog-ios", "posthog-android", "posthog-react-native", "posthog-flutter"]

    /// The `Surface` an event came from, as a HogQL string expression. `$lib`, `$os` and `$is_identified` are set
    /// by PostHog's SDKs; an event without `$lib` was sent to the capture API directly (a server or desktop client).
    static let surface: String = {
        let mobile = mobileLibraries.map(literal).joined(separator: ", ")
        return "multiIf(properties.$lib = 'web', if(ifNull(toString(properties.$is_identified), '') = 'true', 'web', 'visitors'), "
            + "properties.$lib IN (\(mobile)), multiIf(properties.$os IN ('iOS', 'iPadOS'), 'ios', properties.$os = 'Android', 'android', 'other'), "
            + "'other')"
    }()

    /// The condition that keeps a project's included surfaces, or nil when it includes them all (no filter at all).
    public static func scope(excluding excluded: Set<Surface>) -> String? {
        guard !excluded.isEmpty else { return nil }
        let names = excluded.map(\.rawValue).sorted().map(literal).joined(separator: ", ")
        return "\(surface) NOT IN (\(names))"
    }

    /// People and their surfaces over the last 30 days, to choose what to count and to pick the defaults.
    public static func surfaceStats(clock: ProjectClock) -> String {
        "SELECT \(surface) AS surface, uniq(person_id) AS people FROM events "
            + "WHERE timestamp >= fromUnixTimestamp(\(seconds(clock.now) - 30 * 86_400)) GROUP BY surface ORDER BY people DESC"
    }

    // MARK: Every refresh

    /// What one column of `counts` holds.
    public enum CountsColumn: Hashable, Sendable {
        case newToday, newYesterday, newWeek, newWeekBefore, revenue, orders
        case metric(Metric)
    }

    /// People who did `event` while `condition` holds: a person who signs up twice is still one new user.
    static func people(did event: String, _ condition: String) -> String {
        "uniqExactIf(person_id, event = \(literal(event)) AND \(condition))"
    }

    /// Event-based counts in one scan: new users by their event (today, yesterday by now and, when `week`, the last
    /// 7 days and the 7 before), revenue and orders when an event carries revenue, and each event metric in
    /// `events`. The columns say what each position holds.
    public static func counts(settings: MetricSettings, events: [Metric], week: Bool, clock: ProjectClock) -> (sql: String, columns: [CountsColumn])? {
        let today = at(clock.todayStart)
        let days = clock.dayStarts(days: recentDays)
        var columns: [(CountsColumn, String)] = []
        var names: Set<String> = []

        if case .event(let name) = settings.newUsers {
            names.insert(name)
            columns.append((.newToday, people(did: name, "timestamp >= \(today)")))
            columns.append((.newYesterday, people(did: name, "timestamp >= \(at(clock.yesterdayStart)) AND timestamp < \(at(clock.sameTimeYesterday))")))
            if week {
                columns.append((.newWeek, people(did: name, "timestamp >= \(at(days[7]))")))
                columns.append((.newWeekBefore, people(did: name, "timestamp >= \(at(days[0])) AND timestamp < \(at(days[7]))")))
            }
        }
        if case .posthogEvent(let name, let valueProperty) = settings.revenue {
            names.insert(name)
            columns.append((.revenue, "sumIf(toFloat(\(property(valueProperty))), event = \(literal(name)) AND timestamp >= \(today))"))
            columns.append((.orders, "countIf(event = \(literal(name)) AND timestamp >= \(today))"))
        }
        for metric in events {
            guard case .event(let name, let byPeople) = metric else { continue }
            names.insert(name)
            let condition = "timestamp >= \(today)"
            columns.append((.metric(metric), byPeople ? people(did: name, condition) : "countIf(event = \(literal(name)) AND \(condition))"))
        }
        guard !columns.isEmpty else { return nil }
        let start = columns.contains { $0.0 == .newWeek } ? days[0] : clock.yesterdayStart
        let eventList = names.sorted().map(literal).joined(separator: ", ")
        let select = columns.enumerated().map { "\($1.1) AS c\($0)" }.joined(separator: ", ")
        return ("SELECT \(select) FROM events WHERE timestamp >= \(at(start)) AND event IN (\(eventList))", columns.map(\.0))
    }

    /// Which of these events the project sent since `since`, to choose defaults when a project is added.
    public static func eventsSeen(_ names: [String], since: Date) -> String {
        let list = names.map(literal).joined(separator: ", ")
        return "SELECT DISTINCT event FROM events WHERE timestamp >= fromUnixTimestamp(\(seconds(since))) AND event IN (\(list))"
    }

    /// Today's people in one scan from yesterday's start: active today and yesterday by now, online in the last
    /// minute and page views today. Online and page views count any event of the product, actives only its activity
    /// event.
    public static func peopleToday(_ scope: PeopleScope, clock: ProjectClock) -> String {
        let activity = and(scope.activity)
        let columns = [
            "uniqExactIf(\(scope.unit), timestamp >= \(at(clock.todayStart))\(activity)) AS active_today",
            "uniqExactIf(\(scope.unit), timestamp < \(at(clock.sameTimeYesterday))\(activity)) AS active_yesterday",
            "uniqExactIf(\(scope.unit), timestamp >= now() - INTERVAL 1 MINUTE) AS online",
            "countIf(timestamp >= \(at(clock.todayStart)) AND event IN ('$pageview', '$screen')) AS views"
        ]
        return "SELECT \(columns.joined(separator: ", ")) FROM events WHERE timestamp >= \(at(clock.yesterdayStart))\(and(scope.filter))"
    }

    /// The last 14 days' active people in one scan of the activity event alone (cheap: events are stored by name):
    /// the last 7 days counting today and the 7 before, then each day, today last. Whole days in the project's zone,
    /// as PostHog's charts count them.
    public static func peopleDays(_ scope: PeopleScope, clock: ProjectClock) -> String {
        let days = clock.dayStarts(days: recentDays)
        var columns = [
            "uniqExactIf(\(scope.unit), timestamp >= \(at(days[7]))) AS week",
            "uniqExactIf(\(scope.unit), timestamp < \(at(days[7]))) AS week_before"
        ]
        for (index, start) in days.enumerated() {
            let end = index + 1 < days.count ? " AND timestamp < \(at(days[index + 1]))" : ""
            columns.append("uniqExactIf(\(scope.unit), timestamp >= \(at(start))\(end)) AS d\(index)")
        }
        return "SELECT \(columns.joined(separator: ", ")) FROM events WHERE timestamp >= \(at(days[0]))\(and(scope.activeFilter))"
    }

    /// When each person within reach first used the product and on which platform, as `first` and `p`.
    static func firstUse(_ scope: PeopleScope, from start: Date, until end: Date? = nil, lookbackDays: Int = firstSeenLookbackDays) -> String {
        let until = end.map { " AND timestamp < \(at($0))" } ?? ""
        return "(SELECT min(timestamp) AS first, argMin(\(scope.platform), timestamp) AS p FROM events "
            + "WHERE timestamp >= \(at(scope.lookback(from: start, days: lookbackDays)))\(until)\(and(scope.activeFilter)) GROUP BY \(scope.unit))"
    }

    /// People who started using the product in the last 14 days, one row per platform: today, yesterday by now, the
    /// last 7 days and the 7 before. New users when no event counts them, and today's part of the total.
    public static func firstSeen(_ scope: PeopleScope, clock: ProjectClock) -> String {
        let days = clock.dayStarts(days: recentDays)
        let columns = [
            "countIf(first >= \(at(clock.todayStart))) AS today",
            "countIf(first >= \(at(clock.yesterdayStart)) AND first < \(at(clock.sameTimeYesterday))) AS yesterday",
            "countIf(first >= \(at(days[7]))) AS week",
            "countIf(first < \(at(days[7]))) AS week_before"
        ]
        return "SELECT p, \(columns.joined(separator: ", ")) FROM \(firstUse(scope, from: days[0])) WHERE first >= \(at(days[0])) GROUP BY p"
    }

    // MARK: Hourly and daily

    /// People active over the last 30 days counting today. One scan of the window, so it is read hourly.
    public static func month(_ scope: PeopleScope, clock: ProjectClock) -> String {
        "SELECT uniqExact(\(scope.unit)) FROM events WHERE timestamp >= \(at(clock.historyStart(days: 30)))\(and(scope.activeFilter))"
    }

    /// Everyone counted before `date` (since the counting's first day), by the platform each was first seen on. Scans
    /// the whole history, so it runs once per project and counting; `tallyMove` carries it forward.
    public static func tally(before date: Date, _ scope: PeopleScope) -> String {
        let since = scope.since.map { " AND timestamp >= \(at($0))" } ?? ""
        return "SELECT p, count() FROM (SELECT argMin(\(scope.platform), timestamp) AS p FROM events "
            + "WHERE timestamp < \(at(date))\(since)\(and(scope.activeFilter)) GROUP BY \(scope.unit)) GROUP BY p"
    }

    /// People first seen from `since` up to today's start (not in the year before), by platform: what moves a tally
    /// from `since` to today.
    public static func tallyMove(since: Date, _ scope: PeopleScope, clock: ProjectClock) -> String {
        "SELECT p, count() FROM \(firstUse(scope, from: since, until: clock.todayStart, lookbackDays: tallyLookbackDays)) WHERE first >= \(at(since)) GROUP BY p"
    }

    // MARK: Board

    /// Active people per day and platform over the last `days` days.
    public static func boardActive(_ scope: PeopleScope, clock: ProjectClock, days: Int) -> String {
        "SELECT \(day("timestamp", clock: clock)) AS day, \(scope.platform) AS p, uniqExact(\(scope.unit)) FROM events "
            + "WHERE timestamp >= \(at(clock.historyStart(days: days)))\(and(scope.activeFilter)) GROUP BY day, p"
    }

    /// First-seen people per day and platform over the last `days` days.
    public static func boardFirstSeen(_ scope: PeopleScope, clock: ProjectClock, days: Int) -> String {
        let start = clock.historyStart(days: days)
        return "SELECT \(day("first", clock: clock)) AS day, p, count() FROM \(firstUse(scope, from: start)) WHERE first >= \(at(start)) GROUP BY day, p"
    }

    /// People who sent the new-user event per day and platform, wherever they sent it from.
    public static func boardSignups(event: String, platform: String, clock: ProjectClock, days: Int) -> String {
        "SELECT \(day("timestamp", clock: clock)) AS day, \(platform) AS p, uniqExact(person_id) FROM events "
            + "WHERE event = \(literal(event)) AND timestamp >= \(at(clock.historyStart(days: days))) GROUP BY day, p"
    }

    /// Revenue per day from the event that carries it.
    public static func boardRevenue(event: String, valueProperty: String, clock: ProjectClock, days: Int) -> String {
        "SELECT \(day("timestamp", clock: clock)) AS day, sum(toFloat(\(property(valueProperty)))) FROM events "
            + "WHERE event = \(literal(event)) AND timestamp >= \(at(clock.historyStart(days: days))) GROUP BY day"
    }

    /// People active each week since `firstWeek`, split by whether it was their first week. Weeks start on Sunday
    /// (`mode` 0) or Monday (`mode` 1), as the PostHog project says.
    public static func weeks(_ scope: PeopleScope, clock: ProjectClock, firstWeek: Date, mode: Int) -> String {
        let zone = literal(clock.timeZone.identifier)
        let pairs = "SELECT \(scope.unit) AS u, toStartOfWeek(toTimeZone(timestamp, \(zone)), \(mode)) AS week FROM events "
            + "WHERE timestamp >= \(at(scope.lookback(from: firstWeek)))\(and(scope.activeFilter)) GROUP BY u, week"
        return "SELECT toString(week) AS start, countIf(week = fw) AS new, countIf(week > fw) AS returning FROM "
            + "(SELECT week, min(week) OVER (PARTITION BY u) AS fw FROM (\(pairs))) "
            + "WHERE week >= toDate(\(literal(clock.dayKey(firstWeek)))) GROUP BY week ORDER BY week"
    }

    // MARK: Pickers and detail lists

    /// Events of the last 7 days with how many people sent each and how often, most people first.
    public static func eventStats(since: Date, limit: Int = 200) -> String {
        "SELECT event, uniq(person_id) AS people, count() AS times FROM events WHERE timestamp >= fromUnixTimestamp(\(seconds(since))) "
            + "GROUP BY event ORDER BY people DESC LIMIT \(limit)"
    }

    /// How many of the last day's events a condition keeps, to check a condition typed by hand before using it.
    public static func conditionCheck(_ condition: String, clock: ProjectClock) -> String {
        "SELECT countIf(\(condition)), count() FROM events WHERE timestamp >= \(at(clock.now.addingTimeInterval(-86_400)))"
    }

    /// Today's orders, newest first. Product names come from whichever common property the event carries.
    public static func orders(event: String, valueProperty: String, since: Date, limit: Int = 50) -> String {
        let fields = ["product_name", "product", "plan", "plan_tier", "billing_interval", "product_id", "sku"]
            .map { "toString(\(property($0)))" }
            .joined(separator: ", ")
        return "SELECT toString(uuid), toString(timestamp), toFloat(\(property(valueProperty))), toString(properties.$geoip_country_code), \(fields) "
            + "FROM events WHERE event = \(literal(event)) AND timestamp >= fromUnixTimestamp(\(seconds(since))) "
            + "ORDER BY timestamp DESC LIMIT \(limit)"
    }

    /// "Pro 月付" / "Pro 年付" in the person's language.
    static func planName(_ tier: String, yearly: Bool) -> String {
        yearly ? String(localized: "\(tier) 年付", bundle: .module) : String(localized: "\(tier) 月付", bundle: .module)
    }

    /// Readable product name from the order row's property columns.
    public static func productName(_ values: [String?]) -> String? {
        let named = values.prefix(3).compactMap { $0 }.first { !$0.isEmpty && $0 != "null" }
        if let named { return named }
        let tier = values[3].flatMap { $0.isEmpty || $0 == "null" ? nil : $0 }
        let interval = values[4].flatMap { $0.isEmpty || $0 == "null" ? nil : $0 }
        if let tier {
            let label = tier.prefix(1).uppercased() + tier.dropFirst()
            switch interval?.lowercased() {
            case "month", "monthly": return planName(label, yearly: false)
            case "year", "yearly", "annual", "annually": return planName(label, yearly: true)
            default: return label
            }
        }
        return values.dropFirst(5).compactMap { $0 }.first { !$0.isEmpty && $0 != "null" }
    }
}

/// Turns query rows into the pieces of a snapshot.
public enum PostHogParsing {
    /// The event names returned by `PostHogQueries.eventsSeen`.
    public static func eventNames(_ rows: [[JSONValue]]) -> Set<String> {
        Set(rows.compactMap { row in
            if case .string(let name)? = row.first { return name }
            return nil
        })
    }

    public struct Counts: Equatable, Sendable {
        public var values: [Metric: Double] = [:]
        public var previous: [Metric: Double] = [:]
    }

    /// Reads a `counts` row by its columns: new users, revenue and orders land under their metrics.
    public static func counts(_ row: [JSONValue], columns: [PostHogQueries.CountsColumn]) -> Counts {
        var counts = Counts()
        for (column, value) in zip(columns, row) {
            switch column {
            case .newToday: counts.values[.newUsers] = value.double
            case .newYesterday: counts.previous[.newUsers] = value.double
            case .newWeek: counts.values[.newWeek] = value.double
            case .newWeekBefore: counts.previous[.newWeek] = value.double
            case .revenue: counts.values[.revenue] = value.double ?? 0
            case .orders: counts.values[.orders] = value.double ?? 0
            case .metric(let metric): counts.values[metric] = value.double ?? 0
            }
        }
        return counts
    }

    public struct People: Equatable, Sendable {
        public var values: [Metric: Double] = [:]
        public var previous: [Metric: Double] = [:]
        public var daily: [Int] = []
    }

    /// The `peopleToday` row (today, yesterday by now, online, views) and the `peopleDays` row (the week, the week
    /// before, then each day).
    public static func people(today: [JSONValue], days: [JSONValue]) -> People {
        var people = People()
        if today.count >= 4 {
            people.values[.activeToday] = today[0].double
            people.previous[.activeToday] = today[1].double
            people.values[.online] = today[2].double
            people.values[.pageviews] = today[3].double
        }
        if days.count >= 2 {
            people.values[.activeWeek] = days[0].double
            people.previous[.activeWeek] = days[1].double
            people.daily = days.dropFirst(2).map { $0.int ?? 0 }
        }
        return people
    }

    public struct FirstSeen: Equatable, Sendable {
        public var today = 0
        public var yesterday = 0
        public var week = 0
        public var weekBefore = 0
        public var todayByPlatform: [String: Int] = [:]
    }

    /// The `firstSeen` rows, one per platform, added up.
    public static func firstSeen(_ rows: [[JSONValue]]) -> FirstSeen {
        var result = FirstSeen()
        for row in rows where row.count >= 5 {
            let platform = row[0].string ?? ""
            let today = row[1].int ?? 0
            result.today += today
            result.yesterday += row[2].int ?? 0
            result.week += row[3].int ?? 0
            result.weekBefore += row[4].int ?? 0
            if today > 0 { result.todayByPlatform[platform, default: 0] += today }
        }
        return result
    }

    /// Rows of a platform and a count (`tally`, `tallyMove`).
    public static func platformCounts(_ rows: [[JSONValue]]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in rows where row.count >= 2 {
            counts[row[0].string ?? "", default: 0] += row[1].int ?? 0
        }
        return counts
    }

    /// Rows of a day, a platform and a count, by day key ("yyyy-MM-dd").
    public static func dailyByPlatform(_ rows: [[JSONValue]]) -> [String: [String: Int]] {
        var days: [String: [String: Int]] = [:]
        for row in rows where row.count >= 3 {
            guard let key = row[0].string?.prefix(10) else { continue }
            days[String(key), default: [:]][row[1].string ?? "", default: 0] += row[2].int ?? 0
        }
        return days
    }

    /// Rows of a day and an amount, by day key.
    public static func dailyAmounts(_ rows: [[JSONValue]]) -> [String: Double] {
        var days: [String: Double] = [:]
        for row in rows where row.count >= 2 {
            guard let key = row[0].string?.prefix(10) else { continue }
            days[String(key), default: 0] += row[1].double ?? 0
        }
        return days
    }

    public static func surfaceStats(_ rows: [[JSONValue]]) -> [SurfaceStat] {
        rows.compactMap { row in
            guard row.count >= 2, let name = row[0].string, let surface = Surface(rawValue: name) else { return nil }
            return SurfaceStat(surface: surface, people: row[1].int ?? 0)
        }
    }

    public static func eventStats(_ rows: [[JSONValue]]) -> [EventStat] {
        rows.compactMap { row in
            guard row.count >= 3, let name = row[0].string, !EventStat.hidden.contains(name) else { return nil }
            return EventStat(name: name, people: row[1].int ?? 0, times: row[2].int ?? 0)
        }
    }

    public static func orders(_ rows: [[JSONValue]], projectId: UUID) -> [Order] {
        rows.compactMap { row in
            guard row.count >= 4, let id = row[0].string, let dateText = row[1].string, let date = ISO8601.parse(dateText) else { return nil }
            let props = row.dropFirst(4).map { value -> String? in
                guard let text = value.string, text != "null" else { return nil }
                return text
            }
            let country = row[3].string.flatMap { $0 == "null" || $0.isEmpty ? nil : $0 }
            return Order(
                id: id,
                projectId: projectId,
                date: date,
                amount: row[2].double ?? 0,
                product: PostHogQueries.productName(Array(props) + Array(repeating: nil, count: max(0, 7 - props.count))),
                country: country
            )
        }
    }
}
