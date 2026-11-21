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

    /// One count column per hour of today so far (at most 25, on the day clocks go back), so the
    /// response size stays fixed however many people sign up.
    static func hourColumns(_ condition: String, column: String, clock: ProjectClock) -> [String] {
        let today = seconds(clock.todayStart)
        return (0..<min(25, clock.hoursSoFar)).map { hour in
            let from = today + hour * 3600
            return "countIf(\(condition) AND \(column) >= fromUnixTimestamp(\(from)) AND \(column) < fromUnixTimestamp(\(from + 3600))) AS h\(hour)"
        }
    }

    /// Event-based counts for the card: new users (today and yesterday by now), revenue, orders, the extra count and hourly new users.
    public static func eventCounts(metrics: MetricSettings, clock: ProjectClock) -> String? {
        let today = seconds(clock.todayStart)
        let yesterday = seconds(clock.yesterdayStart)
        let yesterdayNow = seconds(clock.sameTimeYesterday)
        var columns: [String] = []
        var events: [String] = []

        if case .event(let name) = metrics.newUsers {
            events.append(name)
            columns.append("countIf(event = \(literal(name)) AND timestamp >= fromUnixTimestamp(\(today))) AS new_today")
            columns.append("countIf(event = \(literal(name)) AND timestamp >= fromUnixTimestamp(\(yesterday)) AND timestamp < fromUnixTimestamp(\(yesterdayNow))) AS new_yesterday")
        }
        if case .posthogEvent(let name, let valueProperty) = metrics.revenue {
            events.append(name)
            columns.append("sumIf(toFloat(\(property(valueProperty))), event = \(literal(name)) AND timestamp >= fromUnixTimestamp(\(today))) AS revenue")
            columns.append("countIf(event = \(literal(name)) AND timestamp >= fromUnixTimestamp(\(today))) AS sales")
        }
        switch metrics.extra {
        case .installs:
            let install = literal(MetricSettings.installEvent)
            events.append(MetricSettings.installEvent)
            columns.append("countIf(event = \(install) AND timestamp >= fromUnixTimestamp(\(today))) AS extra")
        case .event(let name, _):
            events.append(name)
            columns.append("countIf(event = \(literal(name)) AND timestamp >= fromUnixTimestamp(\(today))) AS extra")
        case .none:
            break
        }
        // Hour columns go last so the fixed columns above keep stable positions.
        if case .event(let name) = metrics.newUsers {
            columns += hourColumns("event = \(literal(name))", column: "timestamp", clock: clock)
        }
        guard !columns.isEmpty else { return nil }
        let eventList = Array(Set(events)).sorted().map(literal).joined(separator: ", ")
        return "SELECT \(columns.joined(separator: ", ")) FROM events WHERE timestamp >= fromUnixTimestamp(\(yesterday)) AND event IN (\(eventList))"
    }

    /// Which of these events the project sent since `since`, to choose defaults when a project is added.
    public static func eventsSeen(_ names: [String], since: Date) -> String {
        let list = names.map(literal).joined(separator: ", ")
        return "SELECT DISTINCT event FROM events WHERE timestamp >= fromUnixTimestamp(\(seconds(since))) AND event IN (\(list))"
    }

    /// How far back a person must be unseen to count as new. Bounds every first-seen query to this window plus the
    /// days shown, so its cost follows the project's monthly event volume, not its whole history.
    public static let firstSeenLookbackDays = 30

    /// Each person's first event within the lookback, for `firstSeen` and `firstSeenHistory`. Based on events, not the
    /// persons table: projects that send anonymous events (no person profiles) still have new people.
    static func firstEvents(since start: Date) -> String {
        let lookback = seconds(start) - firstSeenLookbackDays * 86_400
        return "(SELECT person_id, min(timestamp) AS first FROM events WHERE timestamp >= fromUnixTimestamp(\(lookback)) GROUP BY person_id)"
    }

    /// People seen for the first time (not in the previous 30 days), for projects that count new users that way.
    public static func firstSeen(clock: ProjectClock) -> String {
        let today = seconds(clock.todayStart)
        let yesterday = seconds(clock.yesterdayStart)
        let yesterdayNow = seconds(clock.sameTimeYesterday)
        let columns = [
            "countIf(first >= fromUnixTimestamp(\(today))) AS new_today",
            "countIf(first >= fromUnixTimestamp(\(yesterday)) AND first < fromUnixTimestamp(\(yesterdayNow))) AS new_yesterday"
        ] + hourColumns("1 = 1", column: "first", clock: clock)
        return "SELECT \(columns.joined(separator: ", ")) FROM \(firstEvents(since: clock.yesterdayStart)) WHERE first >= fromUnixTimestamp(\(yesterday))"
    }

    /// People active in the last minute and people active today.
    public static func presence(clock: ProjectClock) -> String {
        "SELECT uniqIf(distinct_id, timestamp >= now() - INTERVAL 1 MINUTE) AS online, uniq(person_id) AS active "
            + "FROM events WHERE timestamp >= fromUnixTimestamp(\(seconds(clock.todayStart)))"
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
        var columns = ["toString(toStartOfDay(timestamp)) AS day", "uniq(person_id) AS active"]
        if case .event(let name) = metrics.newUsers {
            columns.append("countIf(event = \(literal(name))) AS new_users")
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
        return "SELECT toString(toStartOfDay(first)) AS day, count() AS new_users FROM \(firstEvents(since: start)) "
            + "WHERE first >= fromUnixTimestamp(\(seconds(start))) GROUP BY day ORDER BY day"
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
            case "month", "monthly": return label + " 月付"
            case "year", "yearly", "annual", "annually": return label + " 年付"
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
        public var newToday: Int?
        public var newYesterday: Int?
        public var hourly: [Int]
        public var revenue: Double?
        public var sales: Int?
        public var extra: Int?
    }

    /// Reads the `eventCounts` row; column positions follow the query builder's order, hour columns last.
    public static func counts(_ row: [JSONValue], metrics: MetricSettings) -> Counts {
        var index = 0
        func next() -> JSONValue? {
            defer { index += 1 }
            return index < row.count ? row[index] : nil
        }
        var counts = Counts(newToday: nil, newYesterday: nil, hourly: [], revenue: nil, sales: nil, extra: nil)
        if case .event = metrics.newUsers {
            counts.newToday = next()?.int
            counts.newYesterday = next()?.int
        }
        if case .posthogEvent = metrics.revenue {
            counts.revenue = next()?.double ?? 0
            counts.sales = next()?.int ?? 0
        }
        if metrics.extra != .none {
            counts.extra = next()?.int
        }
        if case .event = metrics.newUsers {
            counts.hourly = row.dropFirst(index).map { $0.int ?? 0 }
        }
        return counts
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
