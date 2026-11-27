import Foundation

/// The PostHog dashboards of the demo projects, so importing a dashboard can be tried, tested and shown without a
/// PostHog account. Their charts draw from the same made-up world as the cards.
enum DemoDashboards {
    static func list(for projectId: UUID) -> [DashboardSummary] {
        switch projectId {
        case DemoWorld.lumenId: [DashboardSummary(id: 101, name: "Product health", pinned: true), DashboardSummary(id: 102, name: "Growth")]
        case DemoWorld.ferryId: [DashboardSummary(id: 201, name: "Launch & Business", pinned: true)]
        default: []
        }
    }

    static func detail(_ ref: DashboardRef) -> DashboardDetail {
        let tiles: [InsightTile] = switch ref.id {
        case 101, 201:
            [
                trends(ref.id * 10 + 1, "Daily active by platform", display: "ActionsBar", event: "app_opened", math: "dau", breakdown: "$os", in: ref),
                trends(ref.id * 10 + 2, "New users today", display: "BoldNumber", event: MetricSettings.signupEvent, math: "total", in: ref),
                trends(ref.id * 10 + 3, "Weekly active", display: "ActionsLineGraph", event: "app_opened", math: "weekly_active", in: ref),
                trends(ref.id * 10 + 4, "Installs by platform", display: "ActionsPie", event: "app_installed", math: "total", breakdown: "$os", in: ref),
                InsightTile(id: ref.id * 10 + 5, name: "Signup funnel", kind: .unsupported, query: nil, dashboard: ref)
            ]
        case 102:
            [trends(1021, "Signups", display: "ActionsLineGraph", event: MetricSettings.signupEvent, math: "total", in: ref)]
        default:
            []
        }
        return DashboardDetail(ref: ref, tiles: tiles)
    }

    /// A trends chart counting `event`; people charts keep to production builds, the way a real dashboard leaves
    /// out development ones.
    private static func trends(_ id: Int, _ name: String, display: String, event: String, math: String, breakdown: String? = nil, in ref: DashboardRef) -> InsightTile {
        var source: [String: JSONValue] = [
            "kind": .string("TrendsQuery"),
            "series": .array([.object(["kind": .string("EventsNode"), "event": .string(event), "math": .string(math)])]),
            "trendsFilter": .object(["display": .string(display)])
        ]
        if math != "total" {
            source["properties"] = .array([.object(["key": .string("environment"), "value": .array([.string("production")]), "operator": .string("exact"), "type": .string("event")])])
        }
        if let breakdown {
            source["breakdownFilter"] = .object(["breakdown_type": .string("event"), "breakdown": .string(breakdown)])
        }
        return InsightTile(id: id, name: name, kind: .trends, display: display, query: .object(source), dashboard: ref)
    }

    /// What a demo chart shows: the last week of the project's board, by platform where the chart splits.
    static func result(_ tile: InsightTile, board: ProjectBoard, snapshot: ProjectSnapshot?, now: Date) -> InsightResult {
        let days = board.days.suffix(7)
        let labels = days.map { Self.label($0.day) }
        func series(_ values: (ProjectBoard.Day) -> [String: Int]) -> [InsightResult.Series] {
            board.platforms.map { platform in
                InsightResult.Series(label: platform, labels: labels, values: days.map { Double(values($0)[platform] ?? 0) })
            }
        }
        switch tile.display {
        case "ActionsBar":
            return InsightResult(series: series(\.active), fetchedAt: now)
        case "BoldNumber":
            let today = Double(days.last.map { $0.new.values.reduce(0, +) } ?? 0)
            return InsightResult(series: [InsightResult.Series(label: tile.name, total: today)], fetchedAt: now)
        case "ActionsPie":
            let parts = snapshot?.platforms ?? []
            return InsightResult(series: parts.map { InsightResult.Series(label: $0.name, total: Double($0.count)) }, fetchedAt: now)
        default:
            let weekly = days.map { Double($0.active.values.reduce(0, +)) * 3.1 }
            return InsightResult(series: [InsightResult.Series(label: tile.name, labels: labels, values: weekly)], fetchedAt: now)
        }
    }

    private static func label(_ day: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
