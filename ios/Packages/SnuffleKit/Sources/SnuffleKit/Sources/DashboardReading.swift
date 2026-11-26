import Foundation

/// Reads PostHog's dashboard JSON into tiles, and works out from them how the dashboard counts people.
public enum DashboardReading {
    // MARK: Tiles

    /// The insights on a dashboard (`GET /api/projects/:id/dashboards/:id/`), in the order it lays them out.
    public static func detail(_ json: JSONValue, ref: DashboardRef) -> DashboardDetail {
        guard case .array(let tiles)? = json["tiles"] else { return DashboardDetail(ref: ref, tiles: []) }
        let placed = tiles.compactMap { tile -> (Int, Int, InsightTile)? in
            guard tile["deleted"] != .bool(true), let insight = tile["insight"], case .object = insight,
                  insight["deleted"] != .bool(true), let id = insight["id"]?.int else { return nil }
            let layout = tile["layouts"]?["sm"]
            return (layout?["y"]?.int ?? Int.max, layout?["x"]?.int ?? 0, self.tile(insight, id: id, dashboard: ref))
        }
        return DashboardDetail(ref: ref, tiles: placed.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2))
    }

    static func tile(_ insight: JSONValue, id: Int, dashboard: DashboardRef) -> InsightTile {
        let name = insight["name"]?.string ?? insight["derived_name"]?.string ?? "#\(id)"
        let detail = insight["description"]?.string
        let query = insight["query"]
        let source = query?["source"]
        switch (query?["kind"]?.string, source?["kind"]?.string) {
        case ("DataVisualizationNode", "HogQLQuery"?), ("DataTableNode", "HogQLQuery"?):
            let settings = query?["chartSettings"]
            let yColumns: [String] = if case .array(let axes)? = settings?["yAxis"] { axes.compactMap { $0["column"]?.string } } else { [] }
            return InsightTile(
                id: id, name: name, detail: detail, kind: .table, display: query?["display"]?.string,
                xColumn: settings?["xAxis"]?["column"]?.string, yColumns: yColumns, query: source, dashboard: dashboard
            )
        case ("InsightVizNode", "TrendsQuery"?):
            return InsightTile(id: id, name: name, detail: detail, kind: .trends, display: source?["trendsFilter"]?["display"]?.string, query: source, dashboard: dashboard)
        default:
            return InsightTile(id: id, name: name, detail: detail, kind: .unsupported, display: nil, query: nil, dashboard: dashboard)
        }
    }

    /// The dashboards of a project (`GET /api/projects/:id/dashboards/`), pinned ones first.
    public static func summaries(_ json: JSONValue) -> [DashboardSummary] {
        guard case .array(let results)? = json["results"] else { return [] }
        return results.compactMap { item -> DashboardSummary? in
            guard item["deleted"] != .bool(true), let id = item["id"]?.int, let name = item["name"]?.string else { return nil }
            return DashboardSummary(id: id, name: name, pinned: item["pinned"] == .bool(true))
        }
        .sorted { ($0.pinned ? 0 : 1, $0.name) < ($1.pinned ? 0 : 1, $1.name) }
    }

    // MARK: Counting

    /// How a dashboard counts people, read from its charts: the event that means using the product, the conditions
    /// its charts share, people or installations, the platform property and the first day.
    public struct Counting: Hashable, Sendable {
        public var activityEvent: String?
        public var conditions: [String]
        public var unit: PeopleUnit
        public var platformProperty: String?
        /// "yyyy-MM-dd": the earliest day the dashboard's totals count from.
        public var since: String?
        public var dashboard: DashboardRef
        /// The charts it was read from.
        public var sources: [String]

        /// `settings` counting people this way. Website visitors are no longer left out by surface: the dashboard's
        /// conditions say who counts.
        public func applied(to settings: MetricSettings, timeZone: TimeZone) -> MetricSettings {
            var next = settings
            next.activityEvent = activityEvent
            next.conditions = conditions
            next.unit = unit
            next.platformProperty = platformProperty
            next.since = since.flatMap { Self.dayStart($0, in: timeZone) }
            next.dashboard = dashboard
            next.excludedSurfaces = []
            return next
        }

        static func dayStart(_ key: String, in zone: TimeZone) -> Date? {
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
    }

    /// People math in a trends series: unique people a day, week or month.
    static let peopleMath: Set<String> = ["dau", "weekly_active", "monthly_active", "unique_group"]

    /// Reads the counting from a dashboard's charts, or nil when none of them counts people.
    public static func counting(_ detail: DashboardDetail) -> Counting? {
        var events: [String: Int] = [:]
        var conditionSets: [[String]] = []
        var platforms: [String] = []
        var sources: [String] = []
        var installs = 0
        var persons = 0
        var since: [String] = []

        for tile in detail.tiles {
            guard let query = tile.query else { continue }
            switch tile.kind {
            case .trends:
                let series = seriesEvents(query)
                guard series.contains(where: { peopleMath.contains($0.math ?? "") }) else { continue }
                for item in series where peopleMath.contains(item.math ?? "") {
                    if let event = item.event { events[event, default: 0] += 1 }
                }
                conditionSets.append(conditions(query["properties"]))
                if let property = breakdownProperty(query) { platforms.append(property) }
                persons += 1
                sources.append(tile.name)
            case .table:
                guard let sql = query["query"]?.string, let people = HogQLScan(sql), people.countsPeople else { continue }
                for event in people.events { events[event, default: 0] += 1 }
                if people.countsInstalls { installs += 1 } else { persons += 1 }
                if let property = people.platformProperty { platforms.append(property) }
                if let day = people.since { since.append(day) }
                conditionSets.append(people.conditions)
                sources.append(tile.name)
            case .unsupported:
                continue
            }
        }
        guard !sources.isEmpty else { return nil }
        // Conditions every people chart keeps to; charts read from structured filters win over ones parsed from SQL.
        let shared = conditionSets.filter { !$0.isEmpty }
        let common = shared.first.map { first in first.filter { condition in shared.allSatisfy { $0.contains(condition) } } } ?? []
        return Counting(
            activityEvent: activity(events),
            conditions: common,
            unit: installs > persons ? .install : .person,
            platformProperty: mostCommon(platforms),
            since: since.min(),
            dashboard: detail.ref,
            sources: sources
        )
    }

    /// The event most people charts count; one that sounds like opening the product wins a tie.
    static func activity(_ events: [String: Int]) -> String? {
        let opening = ["open", "launch", "screen", "pageview", "session", "active", "visit"]
        return events.max { a, b in
            let scoreA = a.value * 10 + (opening.contains { a.key.lowercased().contains($0) } ? 5 : 0)
            let scoreB = b.value * 10 + (opening.contains { b.key.lowercased().contains($0) } ? 5 : 0)
            return (scoreA, b.key) < (scoreB, a.key)
        }?.key
    }

    static func mostCommon(_ names: [String]) -> String? {
        Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +).max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    struct SeriesEvent { var event: String?; var math: String? }

    static func seriesEvents(_ query: JSONValue) -> [SeriesEvent] {
        guard case .array(let series)? = query["series"] else { return [] }
        return series.flatMap { node -> [SeriesEvent] in
            if case .array(let nodes)? = node["nodes"] {
                return nodes.map { SeriesEvent(event: $0["event"]?.string, math: node["math"]?.string ?? $0["math"]?.string) }
            }
            return [SeriesEvent(event: node["event"]?.string, math: node["math"]?.string)]
        }
    }

    static func breakdownProperty(_ query: JSONValue) -> String? {
        let filter = query["breakdownFilter"]
        if case .array(let breakdowns)? = filter?["breakdowns"],
           let first = breakdowns.first(where: { $0["type"]?.string == "event" }) {
            return first["property"]?.string
        }
        if filter?["breakdown_type"]?.string == "event" { return filter?["breakdown"]?.string }
        return nil
    }

    // MARK: Property filters

    /// HogQL conditions from a query's `properties`: a list of filters, or AND groups of them (OR groups are left
    /// out: they say "either", which no single condition can keep).
    static func conditions(_ properties: JSONValue?) -> [String] {
        guard let properties else { return [] }
        var found: [String] = []
        func walk(_ node: JSONValue) {
            switch node {
            case .array(let items):
                items.forEach(walk)
            case .object:
                if let type = node["type"]?.string, type == "AND" || type == "OR", case .array = node["values"] {
                    if type == "AND" || isSingle(node) { walk(node["values"]!) }
                } else if let condition = condition(node) {
                    for part in splitAnd(condition) where !found.contains(part) { found.append(part) }
                }
            default:
                break
            }
        }
        walk(properties)
        return found
    }

    private static func isSingle(_ group: JSONValue) -> Bool {
        if case .array(let values)? = group["values"] { return values.count == 1 }
        return false
    }

    /// One property filter as a HogQL condition; nil for kinds that have no plain condition (cohorts, elements).
    static func condition(_ filter: JSONValue) -> String? {
        let type = filter["type"]?.string
        if type == "hogql" { return filter["key"]?.string }
        guard let key = filter["key"]?.string, type == "event" || type == "person" else { return nil }
        let field = (type == "person" ? "person." : "") + PostHogQueries.property(key)
        let values: [JSONValue] = if case .array(let list)? = filter["value"] { list } else { filter["value"].map { [$0] } ?? [] }
        let literals = values.compactMap(literal)
        let list = literals.joined(separator: ", ")
        switch filter["operator"]?.string ?? "exact" {
        case "exact":
            guard !literals.isEmpty else { return nil }
            return literals.count == 1 ? "\(field) = \(literals[0])" : "\(field) IN (\(list))"
        case "is_not":
            guard !literals.isEmpty else { return nil }
            return literals.count == 1 ? "ifNull(\(field) != \(literals[0]), 1)" : "ifNull(\(field) NOT IN (\(list)), 1)"
        case "icontains":
            return values.first?.string.map { "toString(\(field)) ILIKE \(PostHogQueries.literal("%\($0)%"))" }
        case "not_icontains":
            return values.first?.string.map { "ifNull(toString(\(field)) NOT ILIKE \(PostHogQueries.literal("%\($0)%")), 1)" }
        case "regex":
            return values.first?.string.map { "match(toString(\(field)), \(PostHogQueries.literal($0)))" }
        case "not_regex":
            return values.first?.string.map { "ifNull(NOT match(toString(\(field)), \(PostHogQueries.literal($0))), 1)" }
        case "gt", "gte", "lt", "lte":
            let symbol = ["gt": ">", "gte": ">=", "lt": "<", "lte": "<="][filter["operator"]?.string ?? ""]!
            return values.first?.double.map { "toFloat(\(field)) \(symbol) \(Format.plain($0))" }
        case "is_set":
            return "isNotNull(\(field))"
        case "is_not_set":
            return "isNull(\(field))"
        default:
            return nil
        }
    }

    static func literal(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): PostHogQueries.literal(text)
        case .number(let number): Format.plain(number)
        case .bool(let flag): flag ? "true" : "false"
        default: nil
        }
    }

    /// Splits `a AND b AND c` at the top level (outside brackets and quotes), so each part can be switched on and off.
    public static func splitAnd(_ condition: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var index = condition.startIndex
        while index < condition.endIndex {
            let character = condition[index]
            if let open = quote {
                current.append(character)
                if character == "\\", condition.index(after: index) < condition.endIndex {
                    index = condition.index(after: index)
                    current.append(condition[index])
                } else if character == open {
                    quote = nil
                }
            } else if character == "'" || character == "\"" || character == "`" {
                quote = character
                current.append(character)
            } else if character == "(" {
                depth += 1
                current.append(character)
            } else if character == ")" {
                depth -= 1
                current.append(character)
            } else if depth == 0, condition[index...].uppercased().hasPrefix(" AND "), !current.uppercased().contains("BETWEEN") {
                parts.append(current)
                current = ""
                index = condition.index(index, offsetBy: 5)
                continue
            } else {
                current.append(character)
            }
            index = condition.index(after: index)
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// What a dashboard's HogQL says about counting people, found by reading its text.
struct HogQLScan {
    var countsPeople: Bool
    var countsInstalls: Bool
    var events: [String]
    var conditions: [String]
    var platformProperty: String?
    var since: String?

    init?(_ sql: String) {
        let flat = sql.replacingOccurrences(of: "\n", with: " ")
        countsInstalls = flat.range(of: #"uniq(Exact)?(If)?\(\s*distinct_id"#, options: .regularExpression) != nil
            || flat.range(of: #"GROUP BY\s+distinct_id"#, options: [.regularExpression, .caseInsensitive]) != nil
        let countsPersons = flat.range(of: #"uniq(Exact)?(If)?\(\s*person_id"#, options: .regularExpression) != nil
        countsPeople = countsInstalls || countsPersons
        guard countsPeople else { return nil }
        events = Self.matches(#"event\s*=\s*'([^']+)'"#, in: flat)
        conditions = Self.matches(#"(properties\.[A-Za-z_$][\w$]*\s*(?:=|!=|NOT IN|IN)\s*(?:'[^']*'|\([^)]*\)|-?\d+(?:\.\d+)?))"#, in: flat)
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        platformProperty = Self.matches(#"properties\.([A-Za-z_$]*platform[\w$]*)"#, in: flat).first
        since = Self.matches(#"timestamp\s*>=\s*toDateTime\('(\d{4}-\d{2}-\d{2})"#, in: flat).min()
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
