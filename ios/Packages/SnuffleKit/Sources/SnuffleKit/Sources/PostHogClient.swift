import Foundation

public struct PostHogProject: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var timezone: String?
    public var organizationName: String?

    public init(id: Int, name: String, timezone: String?, organizationName: String?) {
        self.id = id
        self.name = name
        self.timezone = timezone
        self.organizationName = organizationName
    }

    /// The name to show and to suggest for a Snuffle project: PostHog calls a new organization's first project
    /// "Default project", which says nothing, so the organization's name stands in for it.
    public var displayName: String {
        guard name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Default project") == .orderedSame,
              let organizationName, !organizationName.isEmpty else { return name }
        return organizationName
    }
}

/// Reads a PostHog project with HogQL. Every number is one query; all timestamps are passed as Unix seconds so
/// "today" is decided by `ProjectClock`, not by whichever time zone the server assumes.
public struct PostHogClient: Sendable {
    public var host: URL
    public var token: @Sendable () async throws -> String
    public var http: HTTPClient

    public init(host: URL, http: HTTPClient = HTTPClient(), token: @escaping @Sendable () async throws -> String) {
        self.host = host
        self.http = http
        self.token = token
    }

    // MARK: Projects

    /// The signed-in person's email and every project they can open, across all their organizations.
    /// `/api/users/@me/` lists projects only for the current organization; the others are read one by one, and an
    /// organization the credential may not open is skipped rather than failing the whole list.
    public func account() async throws -> (email: String?, projects: [PostHogProject]) {
        let me: Me = try await http.decode(Me.self, try await request("api/users/@me/"), platform: .posthog)
        var organizations = [me.organization].compactMap { $0 }
        let others = (me.organizations ?? []).filter { other in !organizations.contains { $0.id == other.id } }
        organizations += await withTaskGroup(of: (Int, Me.Organization?).self) { group in
            for (index, other) in others.enumerated() {
                group.addTask {
                    let detail = try? await http.decode(Me.Organization.self, try await request("api/organizations/\(other.id)/"), platform: .posthog)
                    return (index, detail)
                }
            }
            var found: [(Int, Me.Organization)] = []
            for await (index, detail) in group {
                if let detail { found.append((index, detail)) }
            }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var result: [PostHogProject] = []
        var seen = Set<Int>()
        for organization in organizations {
            for team in (organization.teams ?? []) + (organization.projects ?? []) where !seen.contains(team.id) {
                seen.insert(team.id)
                result.append(PostHogProject(id: team.id, name: team.name, timezone: team.timezone, organizationName: organization.name))
            }
        }
        if result.isEmpty {
            // Older accounts: fall back to the project list of the current organization.
            struct Page: Decodable { let results: [Row] }
            struct Row: Decodable { let id: Int; let name: String; let timezone: String? }
            let page: Page = try await http.decode(Page.self, try await request("api/projects/"), platform: .posthog)
            result = page.results.map { PostHogProject(id: $0.id, name: $0.name, timezone: $0.timezone, organizationName: nil) }
        }
        return (me.email, result)
    }

    private struct Me: Decodable {
        let email: String?
        struct Organization: Decodable, Sendable {
            struct Team: Decodable, Sendable { let id: Int; let name: String; let timezone: String? }
            let id: String
            let name: String
            let teams: [Team]?
            let projects: [Team]?
        }
        let organization: Organization?
        let organizations: [Organization]?
    }

    /// The project's time zone, read fresh in case it was changed in PostHog.
    public func timeZone(projectId: Int) async throws -> String? {
        struct Row: Decodable { let timezone: String? }
        let row: Row = try await http.decode(Row.self, try await request("api/projects/\(projectId)/"), platform: .posthog)
        return row.timezone
    }

    // MARK: Query

    public func query(projectId: Int, _ hogql: String, name: String) async throws -> [[JSONValue]] {
        struct Body: Encodable {
            struct Query: Encodable { let kind = "HogQLQuery"; let query: String }
            let query: Query
            let name: String
        }
        struct Response: Decodable { let results: [[JSONValue]]? }
        var request = try await request("api/projects/\(projectId)/query/")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(query: .init(query: hogql), name: name))
        let response: Response = try await http.decode(Response.self, request, platform: .posthog)
        return response.results ?? []
    }

    private func request(_ path: String) async throws -> URLRequest {
        var request = URLRequest(url: host.appending(path: path))
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        return request
    }
}

/// HogQL for every number Snuffle shows. Kept separate from the transport so tests can check the SQL itself.
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

    /// One column per hour of today so far (at most 25, on the day clocks go back), so the response size stays
    /// fixed however many people sign up. `count` turns a condition into the column's aggregate.
    static func hourColumns(column: String, clock: ProjectClock, count: (String) -> String) -> [String] {
        let today = seconds(clock.todayStart)
        return (0..<min(25, clock.hoursSoFar)).map { hour in
            let from = today + hour * 3600
            return count("\(column) >= fromUnixTimestamp(\(from)) AND \(column) < fromUnixTimestamp(\(from + 3600))")
        }
    }

    /// People who did `event` while `condition` holds: a person who signs up twice is still one new user.
    static func people(did event: String, _ condition: String? = nil) -> String {
        "uniqExactIf(person_id, event = \(literal(event))\(condition.map { " AND \($0)" } ?? ""))"
    }

    /// The day an event falls on in the project's zone, as "yyyy-MM-dd", so history days match `ProjectClock`
    /// even if PostHog's own project zone has since changed.
    static func day(_ column: String, clock: ProjectClock) -> String {
        "toString(toDate(toTimeZone(\(column), \(literal(clock.timeZone.identifier)))))"
    }

    /// What one column of `counts` holds.
    public enum CountsColumn: Hashable, Sendable {
        case newToday, newYesterday, revenue, orders, hour
        case metric(Metric)
    }

    /// Event-based counts in one scan from the start of yesterday: new users (today and yesterday by now) and their
    /// hours when an event counts them, revenue and orders when an event carries revenue, and each event metric in
    /// `events`. The columns say what each position holds.
    public static func counts(settings: MetricSettings, events: [Metric], clock: ProjectClock) -> (sql: String, columns: [CountsColumn])? {
        let today = seconds(clock.todayStart)
        let yesterday = seconds(clock.yesterdayStart)
        let yesterdayNow = seconds(clock.sameTimeYesterday)
        var columns: [(CountsColumn, String)] = []
        var names: Set<String> = []

        if case .event(let name) = settings.newUsers {
            names.insert(name)
            columns.append((.newToday, people(did: name, "timestamp >= fromUnixTimestamp(\(today))")))
            columns.append((.newYesterday, people(did: name, "timestamp >= fromUnixTimestamp(\(yesterday)) AND timestamp < fromUnixTimestamp(\(yesterdayNow))")))
        }
        if case .posthogEvent(let name, let valueProperty) = settings.revenue {
            names.insert(name)
            columns.append((.revenue, "sumIf(toFloat(\(property(valueProperty))), event = \(literal(name)) AND timestamp >= fromUnixTimestamp(\(today)))"))
            columns.append((.orders, "countIf(event = \(literal(name)) AND timestamp >= fromUnixTimestamp(\(today)))"))
        }
        for metric in events {
            guard case .event(let name, let byPeople) = metric else { continue }
            names.insert(name)
            let condition = "timestamp >= fromUnixTimestamp(\(today))"
            columns.append((.metric(metric), byPeople ? people(did: name, condition) : "countIf(event = \(literal(name)) AND \(condition))"))
        }
        if case .event(let name) = settings.newUsers {
            columns += hourColumns(column: "timestamp", clock: clock) { people(did: name, $0) }.map { (.hour, $0) }
        }
        guard !columns.isEmpty else { return nil }
        let eventList = names.sorted().map(literal).joined(separator: ", ")
        let select = columns.enumerated().map { "\($1.1) AS c\($0)" }.joined(separator: ", ")
        return ("SELECT \(select) FROM events WHERE timestamp >= fromUnixTimestamp(\(yesterday)) AND event IN (\(eventList))", columns.map(\.0))
    }

    /// Which of these events the project sent since `since`, to choose defaults when a project is added.
    public static func eventsSeen(_ names: [String], since: Date) -> String {
        let list = names.map(literal).joined(separator: ", ")
        return "SELECT DISTINCT event FROM events WHERE timestamp >= fromUnixTimestamp(\(seconds(since))) AND event IN (\(list))"
    }

    /// How far back a person must be unseen to count as new. Bounds every first-seen query to this window plus the
    /// days shown, so its cost follows the project's monthly event volume, not its whole history.
    public static let firstSeenLookbackDays = 30

    /// An event from someone using the product, as opposed to a visitor: anonymous web traffic (posthog-js without
    /// an identified person) is someone reading the website. App, desktop, game and server SDKs, and anyone signed
    /// in on the web, count as use. Both properties are set by PostHog's SDKs, so no setup is needed.
    static let productUse = "(ifNull(properties.$lib, '') != 'web' OR ifNull(toString(properties.$is_identified), '') = 'true')"

    /// When each person within the lookback started using the product, as `first`, for `firstSeen` and
    /// `firstSeenHistory`. Visitors are left out (their `first` is the epoch) unless the project has nothing but
    /// visitors, as a website without sign-in does; then everyone counts from their first event. Based on events,
    /// not the persons table: projects that send anonymous events (no person profiles) still have new people.
    static func firstEvents(since start: Date) -> String {
        let lookback = seconds(start) - firstSeenLookbackDays * 86_400
        let people = "SELECT min(timestamp) AS first_event, minIf(timestamp, \(productUse)) AS first_use, max(\(productUse)) AS uses "
            + "FROM events WHERE timestamp >= fromUnixTimestamp(\(lookback)) GROUP BY person_id"
        return "(SELECT if(max(uses) OVER () = 1, first_use, first_event) AS first FROM (\(people)))"
    }

    /// People who started using the product today (not seen in the previous 30 days), for projects without a
    /// signup event.
    public static func firstSeen(clock: ProjectClock) -> String {
        let today = seconds(clock.todayStart)
        let yesterday = seconds(clock.yesterdayStart)
        let yesterdayNow = seconds(clock.sameTimeYesterday)
        let columns = [
            "countIf(first >= fromUnixTimestamp(\(today))) AS new_today",
            "countIf(first >= fromUnixTimestamp(\(yesterday)) AND first < fromUnixTimestamp(\(yesterdayNow))) AS new_yesterday"
        ] + hourColumns(column: "first", clock: clock) { "countIf(\($0))" }.enumerated().map { "\($1) AS h\($0)" }
        return "SELECT \(columns.joined(separator: ", ")) FROM \(firstEvents(since: clock.yesterdayStart)) WHERE first >= fromUnixTimestamp(\(yesterday))"
    }

    /// People active in the last minute, people active today and today's page views, in one scan of today.
    public static func presence(clock: ProjectClock) -> String {
        "SELECT uniqIf(distinct_id, timestamp >= now() - INTERVAL 1 MINUTE) AS online, uniq(person_id) AS active, countIf(event = '$pageview') AS pageviews "
            + "FROM events WHERE timestamp >= fromUnixTimestamp(\(seconds(clock.todayStart)))"
    }

    /// People active in the last 7 days and, when `month`, the last 30, ending now. One scan of the longest window,
    /// so it is read hourly (`Metric.isHourly`), not on every refresh.
    public static func activity(clock: ProjectClock, month: Bool) -> String {
        let week = seconds(clock.now) - 7 * 86_400
        guard month else {
            return "SELECT uniq(person_id) AS week FROM events WHERE timestamp >= fromUnixTimestamp(\(week))"
        }
        return "SELECT uniqIf(person_id, timestamp >= fromUnixTimestamp(\(week))) AS week, uniq(person_id) AS month "
            + "FROM events WHERE timestamp >= fromUnixTimestamp(\(seconds(clock.now) - 30 * 86_400))"
    }

    /// People PostHog has identified (signed in), ever. Profiles of anonymous people are left out: projects that send
    /// anonymous events often have none, so their count would mean nothing.
    public static let totalUsers = "SELECT count() AS identified FROM persons WHERE is_identified = 1"

    /// Events of the last 7 days with how many people sent each and how often, most people first.
    public static func eventStats(since: Date, limit: Int = 200) -> String {
        "SELECT event, uniq(person_id) AS people, count() AS times FROM events WHERE timestamp >= fromUnixTimestamp(\(seconds(since))) "
            + "GROUP BY event ORDER BY people DESC LIMIT \(limit)"
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

    /// Per-day new users, revenue and active people for the history chart.
    public static func history(metrics: MetricSettings, clock: ProjectClock, days: Int) -> String {
        let start = seconds(clock.historyStart(days: days))
        var columns = ["\(day("timestamp", clock: clock)) AS day", "uniq(person_id) AS active"]
        if case .event(let name) = metrics.newUsers {
            columns.append("\(people(did: name)) AS new_users")
        } else {
            columns.append("0 AS new_users")
        }
        if case .posthogEvent(let name, let valueProperty) = metrics.revenue {
            columns.append("sumIf(toFloat(\(property(valueProperty))), event = \(literal(name))) AS revenue")
        } else {
            columns.append("0 AS revenue")
        }
        return "SELECT \(columns.joined(separator: ", ")) FROM events WHERE timestamp >= fromUnixTimestamp(\(start)) GROUP BY day ORDER BY day"
    }

    /// Per-day first-seen people, used when new users are counted that way.
    public static func firstSeenHistory(clock: ProjectClock, days: Int) -> String {
        let start = clock.historyStart(days: days)
        return "SELECT \(day("first", clock: clock)) AS day, count() AS new_users FROM \(firstEvents(since: start)) "
            + "WHERE first >= fromUnixTimestamp(\(seconds(start))) GROUP BY day ORDER BY day"
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
        public var newYesterday: Int?
        public var hourly: [Int] = []
    }

    /// Reads a `counts` row by its columns: new users, revenue and orders land under their metrics.
    public static func counts(_ row: [JSONValue], columns: [PostHogQueries.CountsColumn]) -> Counts {
        var counts = Counts()
        for (column, value) in zip(columns, row) {
            switch column {
            case .newToday: counts.values[.newUsers] = value.double
            case .newYesterday: counts.newYesterday = value.int
            case .revenue: counts.values[.revenue] = value.double ?? 0
            case .orders: counts.values[.orders] = value.double ?? 0
            case .hour: counts.hourly.append(value.int ?? 0)
            case .metric(let metric): counts.values[metric] = value.double ?? 0
            }
        }
        return counts
    }

    public static func eventStats(_ rows: [[JSONValue]]) -> [EventStat] {
        rows.compactMap { row in
            guard row.count >= 3, let name = row[0].string, !EventStat.hidden.contains(name) else { return nil }
            return EventStat(name: name, people: row[1].int ?? 0, times: row[2].int ?? 0)
        }
    }

    /// The `firstSeen` row: new today, new yesterday by now, then one column per hour.
    public static func firstSeen(_ row: [JSONValue]) -> (today: Int?, yesterday: Int?, hourly: [Int]) {
        (row.first?.int, row.count > 1 ? row[1].int : nil, row.dropFirst(2).map { $0.int ?? 0 })
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

    /// History rows keyed by local day ("yyyy-MM-dd"), filled to one point per day.
    public static func history(_ rows: [[JSONValue]], firstSeen: [[JSONValue]]?, clock: ProjectClock, days: Int, hasRevenue: Bool) -> [DailyPoint] {
        var byDay: [String: (active: Int?, newUsers: Int?, revenue: Double?)] = [:]
        for row in rows where row.count >= 4 {
            guard let key = row[0].string?.prefix(10) else { continue }
            byDay[String(key)] = (row[1].int, row[2].int, row[3].double)
        }
        var firstSeenByDay: [String: Int] = [:]
        for row in firstSeen ?? [] where row.count >= 2 {
            if let key = row[0].string?.prefix(10) { firstSeenByDay[String(key)] = row[1].int ?? 0 }
        }
        return clock.dayStarts(days: days).map { day in
            let key = clock.dayKey(day)
            let row = byDay[key]
            let newUsers = firstSeen != nil ? (firstSeenByDay[key] ?? 0) : (row?.newUsers ?? 0)
            return DailyPoint(day: day, newUsers: newUsers, revenue: hasRevenue ? (row?.revenue ?? 0) : nil, active: row?.active ?? 0)
        }
    }
}
