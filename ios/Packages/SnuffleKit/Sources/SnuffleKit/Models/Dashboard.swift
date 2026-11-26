import Foundation

/// A dashboard in a PostHog project, as listed for picking.
public struct DashboardSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var pinned: Bool

    public init(id: Int, name: String, pinned: Bool = false) {
        self.id = id
        self.name = name
        self.pinned = pinned
    }

    public var ref: DashboardRef { DashboardRef(id: id, name: name) }
}

/// One chart on a PostHog dashboard, with the query it was saved with. Snuffle runs that query as it is, so the
/// numbers are the dashboard's own.
public struct InsightTile: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A HogQL query: columns and rows.
        case table
        /// A trends query: one series per event or breakdown value.
        case trends
        /// Funnels, retention, paths and the rest: opened in PostHog instead.
        case unsupported
    }

    public var id: Int
    public var name: String
    public var detail: String?
    public var kind: Kind
    /// PostHog's display: `BoldNumber`, `ActionsLineGraph`, `ActionsBar`, `ActionsStackedBar`, `ActionsPie`, …
    public var display: String?
    /// For tables drawn as charts: the column along the bottom and the columns plotted.
    public var xColumn: String?
    public var yColumns: [String]
    /// What to post to PostHog's query API; nil when the insight has no query Snuffle can run.
    public var query: JSONValue?
    public var dashboard: DashboardRef

    public init(id: Int, name: String, detail: String? = nil, kind: Kind, display: String? = nil, xColumn: String? = nil, yColumns: [String] = [], query: JSONValue?, dashboard: DashboardRef) {
        self.id = id
        self.name = name
        self.detail = detail
        self.kind = kind
        self.display = display
        self.xColumn = xColumn
        self.yColumns = yColumns
        self.query = query
        self.dashboard = dashboard
    }

    public var canDraw: Bool { kind != .unsupported && query != nil }

    /// The insight's page in PostHog.
    public func url(host: URL, projectId: Int) -> URL {
        host.appending(path: "project/\(projectId)/insights/\(id)")
    }
}

/// A dashboard with its charts, in the order the dashboard lays them out.
public struct DashboardDetail: Hashable, Sendable {
    public var ref: DashboardRef
    public var tiles: [InsightTile]

    public init(ref: DashboardRef, tiles: [InsightTile]) {
        self.ref = ref
        self.tiles = tiles
    }
}

/// What running an insight returned, kept in a form that draws without the original JSON.
public struct InsightResult: Codable, Hashable, Sendable {
    public struct Series: Codable, Hashable, Sendable {
        public var label: String
        /// The x-axis labels, e.g. dates.
        public var labels: [String]
        public var values: [Double]
        /// PostHog's own total for the series (unique people over the range for people math), when it gives one.
        public var total: Double?
        /// The comparison period of a "vs previous" chart.
        public var isPrevious: Bool

        public init(label: String, labels: [String] = [], values: [Double] = [], total: Double? = nil, isPrevious: Bool = false) {
            self.label = label
            self.labels = labels
            self.values = values
            self.total = total
            self.isPrevious = isPrevious
        }

        /// The series as one number: PostHog's total, else its values added up.
        public var number: Double { total ?? values.reduce(0, +) }
    }

    public var columns: [String]
    public var rows: [[JSONValue]]
    public var series: [Series]
    public var fetchedAt: Date

    public init(columns: [String] = [], rows: [[JSONValue]] = [], series: [Series] = [], fetchedAt: Date) {
        self.columns = columns
        self.rows = rows
        self.series = series
        self.fetchedAt = fetchedAt
    }

    /// Reads the query API's answer: a table (`columns` and `results`) or trends (`results` of series).
    public static func parse(_ json: JSONValue, at date: Date) -> InsightResult {
        guard case .array(let results)? = json["results"] else { return InsightResult(fetchedAt: date) }
        if case .array(let columns)? = json["columns"] {
            let rows = results.compactMap { row -> [JSONValue]? in
                if case .array(let cells) = row { return cells }
                return nil
            }
            return InsightResult(columns: columns.map { $0.string ?? "" }, rows: rows, fetchedAt: date)
        }
        let series = results.compactMap { item -> Series? in
            guard case .object = item else { return nil }
            let breakdown: String? = {
                if case .array(let values)? = item["breakdown_value"] { return values.compactMap(\.string).joined(separator: " · ") }
                return item["breakdown_value"]?.string
            }()
            let label = breakdown.flatMap { $0.isEmpty ? nil : $0 } ?? item["custom_name"]?.string ?? item["label"]?.string ?? ""
            let values: [Double] = if case .array(let data)? = item["data"] { data.map { $0.double ?? 0 } } else { [] }
            let labels: [String] = if case .array(let names)? = item["labels"] { names.compactMap(\.string) } else if case .array(let days)? = item["days"] { days.compactMap(\.string) } else { [] }
            let total = item["aggregated_value"]?.double ?? (values.isEmpty ? item["count"]?.double : nil)
            return Series(label: label, labels: labels, values: values, total: total, isPrevious: item["compare_label"]?.string == "previous")
        }
        return InsightResult(series: series, fetchedAt: date)
    }

    /// How a tile draws this result.
    public enum Shape: Hashable, Sendable {
        /// Single numbers with their names, and the previous period's when the chart compares.
        case numbers([NamedNumber])
        /// Parts of a whole, e.g. installs by platform.
        case split([NamedNumber])
        /// Bars along `labels`, one stacked segment per series.
        case bars(labels: [String], series: [NamedSeries])
        case table(columns: [String], rows: [[String]])
        case empty
    }

    public struct NamedNumber: Hashable, Sendable {
        public var name: String
        public var value: Double
        public var previous: Double?

        public init(name: String, value: Double, previous: Double? = nil) {
            self.name = name
            self.value = value
            self.previous = previous
        }
    }

    public struct NamedSeries: Hashable, Sendable {
        public var name: String
        public var values: [Double]

        public init(name: String, values: [Double]) {
            self.name = name
            self.values = values
        }
    }

    public func shape(for tile: InsightTile) -> Shape {
        switch tile.kind {
        case .trends: trendsShape(display: tile.display)
        case .table: tableShape(tile)
        case .unsupported: .empty
        }
    }

    private func trendsShape(display: String?) -> Shape {
        let current = series.filter { !$0.isPrevious }
        guard !current.isEmpty else { return .empty }
        switch display ?? "ActionsLineGraph" {
        case "BoldNumber":
            return .numbers(current.map { item in
                let previous = series.first { $0.isPrevious && $0.label == item.label }
                return NamedNumber(name: item.label, value: item.number, previous: previous?.number)
            })
        case "ActionsPie", "ActionsBarValue", "WorldMap", "ActionsTable":
            return .split(current.map { NamedNumber(name: $0.label, value: $0.number) }.sorted { $0.value > $1.value })
        default:
            let labels = current[0].labels
            guard !labels.isEmpty else { return .numbers(current.map { NamedNumber(name: $0.label, value: $0.number) }) }
            return .bars(labels: labels, series: current.prefix(6).map { NamedSeries(name: $0.label, values: $0.values) })
        }
    }

    private func tableShape(_ tile: InsightTile) -> Shape {
        guard !rows.isEmpty, !columns.isEmpty else { return .empty }
        let numeric = columns.indices.filter { index in rows.allSatisfy { index < $0.count && ($0[index].double != nil || $0[index] == .null) } && rows.contains { index < $0.count && $0[index].double != nil } }
        switch tile.display {
        case "BoldNumber":
            guard let first = numeric.first, let value = rows[0][first].double else { return .empty }
            return .numbers([NamedNumber(name: columns[first], value: value)])
        case "ActionsPie":
            guard let value = numeric.first, let name = columns.indices.first(where: { !numeric.contains($0) }) else { break }
            return .split(rows.map { NamedNumber(name: $0[name].string ?? "–", value: $0[value].double ?? 0) }.sorted { $0.value > $1.value })
        case "ActionsBar", "ActionsLineGraph", "ActionsStackedBar", "ActionsAreaGraph":
            let x = tile.xColumn.flatMap(columns.firstIndex(of:)) ?? columns.indices.first { !numeric.contains($0) } ?? 0
            let ys = tile.yColumns.compactMap(columns.firstIndex(of:)).filter { $0 != x }
            let plotted = (ys.isEmpty ? numeric.filter { $0 != x } : ys).prefix(6)
            guard !plotted.isEmpty else { break }
            return .bars(
                labels: rows.map { $0[x].string ?? "" },
                series: plotted.map { column in NamedSeries(name: columns[column], values: rows.map { $0[column].double ?? 0 }) }
            )
        default:
            break
        }
        if rows.count == 1, numeric.count == columns.count {
            return .numbers(numeric.map { NamedNumber(name: columns[$0], value: rows[0][$0].double ?? 0) })
        }
        let shown = Array(columns.prefix(6))
        return .table(columns: shown, rows: rows.prefix(50).map { row in shown.indices.map { index in index < row.count ? Self.text(row[index]) : "" } })
    }

    static func text(_ value: JSONValue) -> String {
        switch value {
        case .null: "–"
        case .number(let number): number == number.rounded() && abs(number) < 1e15 ? Format.number(Int(number)) : String(format: "%.2f", number)
        case .bool(let flag): flag ? "true" : "false"
        case .string(let text): text
        case .array, .object: "…"
        }
    }

    /// Every single number the result shows, to find the dashboard chart that says the same as a Snuffle number.
    public func numbers(for tile: InsightTile) -> [NamedNumber] {
        switch shape(for: tile) {
        case .numbers(let numbers): numbers
        default: []
        }
    }
}
