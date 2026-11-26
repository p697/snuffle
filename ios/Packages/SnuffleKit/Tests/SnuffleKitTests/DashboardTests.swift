import Foundation
import Testing
@testable import SnuffleKit

/// Dashboards shaped like the ones PostHog returns, with made-up names and values.
@Suite("Dashboards")
struct DashboardTests {
    func json(_ text: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    let ref = DashboardRef(id: 7, name: "Launch")

    /// An app dashboard written by hand: trends with a HogQL filter, and HogQL tables counting installations.
    var appDashboard: JSONValue {
        let scope = "properties.client_app = 'demo_mobile' AND properties.app_environment = 'release' AND properties.app_platform IN ('ios','android')"
        return json(#"""
        {"tiles":[
          {"layouts":{"sm":{"x":6,"y":0}},"insight":{"id":3,"name":"Active installations","query":{"kind":"InsightVizNode","source":{"kind":"TrendsQuery","series":[{"kind":"EventsNode","event":"app_opened","math":"dau"}],"properties":[{"type":"hogql","key":"\#(scope)"}],"trendsFilter":{"display":"BoldNumber"}}}}},
          {"layouts":{"sm":{"x":0,"y":0}},"insight":{"id":1,"name":"Total installations","query":{"kind":"DataVisualizationNode","display":"BoldNumber","source":{"kind":"HogQLQuery","query":"SELECT uniqExact(distinct_id) FROM events WHERE timestamp >= toDateTime('2026-09-01 00:00:00') AND \#(scope) AND event='app_opened'"}}}},
          {"layouts":{"sm":{"x":0,"y":4}},"insight":{"id":2,"name":"Daily by platform","query":{"kind":"DataVisualizationNode","display":"ActionsStackedBar","chartSettings":{"xAxis":{"column":"day"},"yAxis":[{"column":"ios"},{"column":"android"}]},"source":{"kind":"HogQLQuery","query":"SELECT toDate(timestamp) AS day, uniqExactIf(distinct_id, properties.app_platform = 'ios') AS ios FROM events WHERE \#(scope) AND event = 'app_opened' AND properties.outcome = 'ok' GROUP BY day"}}}},
          {"layouts":{"sm":{"x":0,"y":8}},"insight":{"id":4,"name":"Quota","query":{"kind":"DataVisualizationNode","source":{"kind":"HogQLQuery","query":"SELECT count() FROM events"}}}},
          {"layouts":{"sm":{"x":0,"y":9}},"insight":{"id":5,"name":"Funnel","query":{"kind":"InsightVizNode","source":{"kind":"FunnelsQuery","series":[]}}}},
          {"deleted":true,"insight":{"id":6,"name":"Gone"}}
        ]}
        """#)
    }

    @Test func tilesKeepTheDashboardsOrderAndKnowWhatTheyCanDraw() {
        let detail = DashboardReading.detail(appDashboard, ref: ref)
        #expect(detail.tiles.map(\.id) == [1, 3, 2, 4, 5])
        #expect(detail.tiles.map(\.kind) == [.table, .trends, .table, .table, .unsupported])
        #expect(detail.tiles[0].display == "BoldNumber")
        #expect(detail.tiles[2].xColumn == "day" && detail.tiles[2].yColumns == ["ios", "android"])
        #expect(!detail.tiles[4].canDraw)
        #expect(detail.tiles.allSatisfy { $0.dashboard == ref })
    }

    @Test func readsTheCountingAnAppDashboardUses() throws {
        let counting = try #require(DashboardReading.counting(DashboardReading.detail(appDashboard, ref: ref)))
        #expect(counting.activityEvent == "app_opened")
        // Conditions every people chart keeps to, one per part so each can be switched off.
        #expect(counting.conditions == ["properties.client_app = 'demo_mobile'", "properties.app_environment = 'release'", "properties.app_platform IN ('ios','android')"])
        #expect(counting.unit == .install, "its tables count distinct_id")
        #expect(counting.platformProperty == "app_platform")
        #expect(counting.since == "2026-09-01")
        #expect(counting.sources == ["Total installations", "Active installations", "Daily by platform"])

        let applied = counting.applied(to: MetricSettings(newUsers: .firstSeen, revenue: .none, excludedSurfaces: [.visitors]), timeZone: TimeZone(identifier: "UTC")!)
        #expect(applied.excludedSurfaces == [], "the dashboard's conditions say who counts")
        #expect(applied.since == ISO8601.parse("2026-09-01T00:00:00Z"))
        #expect(applied.dashboard == ref)
    }

    @Test func readsNestedPropertyGroupsAndThePlatformBreakdown() throws {
        let detail = DashboardReading.detail(json(#"""
        {"tiles":[
          {"insight":{"id":1,"name":"30-day actives","query":{"kind":"InsightVizNode","source":{"kind":"TrendsQuery","series":[{"event":"app_opened","math":"dau"}],"properties":{"type":"AND","values":[{"type":"AND","values":[{"key":"product","operator":"exact","type":"event","value":"demo"},{"key":"environment","operator":"exact","type":"event","value":"production"}]},{"type":"AND","values":[{"key":"product","operator":"exact","type":"event","value":"demo"},{"key":"schema_version","operator":"exact","type":"event","value":1}]}]}}}}},
          {"insight":{"id":2,"name":"Daily by platform","query":{"kind":"InsightVizNode","source":{"kind":"TrendsQuery","series":[{"event":"app_opened","math":"dau"}],"breakdownFilter":{"breakdown_type":"event","breakdowns":[{"property":"app_platform","type":"event"}]},"properties":{"type":"AND","values":[{"type":"AND","values":[{"key":"product","operator":"exact","type":"event","value":"demo"},{"key":"environment","operator":"exact","type":"event","value":"production"},{"key":"schema_version","operator":"exact","type":"event","value":1}]}]}}}}},
          {"insight":{"id":3,"name":"Copiers","query":{"kind":"InsightVizNode","source":{"kind":"TrendsQuery","series":[{"event":"prompt_copied","math":"dau"}],"properties":[]}}}}
        ]}
        """#), ref: ref)
        let counting = try #require(DashboardReading.counting(detail))
        #expect(counting.activityEvent == "app_opened")
        #expect(counting.conditions == ["properties['product'] = 'demo'", "properties['environment'] = 'production'", "properties['schema_version'] = 1"])
        #expect(counting.unit == .person)
        #expect(counting.platformProperty == "app_platform")
        #expect(counting.since == nil)
    }

    @Test func personFiltersAndNegationsBecomeConditionsThatKeepMissingValues() {
        let filters = json(#"""
        [{"key":"device_id","operator":"is_not","type":"person","value":["dev-1"]},
         {"key":"$timezone","operator":"exact","type":"event","value":["Asia/Shanghai","Asia/Taipei"]},
         {"key":"plan","operator":"icontains","type":"event","value":"pro"},
         {"key":"price","operator":"gt","type":"event","value":4.5},
         {"key":"beta","operator":"is_set","type":"event","value":"is_set"},
         {"type":"cohort","key":"id","value":3},
         {"type":"OR","values":[{"key":"a","operator":"exact","type":"event","value":"1"},{"key":"b","operator":"exact","type":"event","value":"2"}]}]
        """#)
        #expect(DashboardReading.conditions(filters) == [
            "ifNull(person.properties['device_id'] != 'dev-1', 1)",
            "properties['$timezone'] IN ('Asia/Shanghai', 'Asia/Taipei')",
            "toString(properties['plan']) ILIKE '%pro%'",
            "toFloat(properties['price']) > 4.5",
            "isNotNull(properties['beta'])"
        ], "cohorts and OR groups have no single condition")
    }

    @Test func splitsConditionsOnlyAtTheTopLevel() {
        #expect(DashboardReading.splitAnd("a = 'x AND y' AND (b = 1 AND c = 2) AND d IN ('p','q')") == ["a = 'x AND y'", "(b = 1 AND c = 2)", "d IN ('p','q')"])
        #expect(DashboardReading.splitAnd("ts BETWEEN 1 AND 2") == ["ts BETWEEN 1 AND 2"])
        #expect(DashboardReading.splitAnd("a = 1 and b = 2") == ["a = 1", "b = 2"])
    }

    @Test func dashboardsWithoutPeopleChartsHaveNoCounting() {
        let detail = DashboardReading.detail(json(#"{"tiles":[{"insight":{"id":1,"name":"Events","query":{"kind":"InsightVizNode","source":{"kind":"TrendsQuery","series":[{"event":"purchase","math":"total"}]}}}}]}"#), ref: ref)
        #expect(DashboardReading.counting(detail) == nil)
        #expect(DashboardReading.summaries(json(#"{"results":[{"id":2,"name":"B"},{"id":1,"name":"A","pinned":true},{"id":3,"name":"Gone","deleted":true}]}"#)).map(\.id) == [1, 2])
    }

    @Test func trendResultsDrawAsNumbersBarsOrParts() {
        let now = Date(timeIntervalSince1970: 0)
        let trend = InsightTile(id: 1, name: "Actives", kind: .trends, display: "BoldNumber", query: .null, dashboard: ref)
        let bold = InsightResult.parse(json(#"{"results":[{"label":"app_opened","custom_name":"Active","data":[],"days":[],"count":0,"aggregated_value":531,"compare_label":"current"},{"label":"app_opened","custom_name":"Active","data":[],"count":0,"aggregated_value":440,"compare_label":"previous"}]}"#), at: now)
        #expect(bold.shape(for: trend) == .numbers([.init(name: "Active", value: 531, previous: 440)]))

        var daily = trend
        daily.display = "ActionsLineGraph"
        let lines = InsightResult.parse(json(#"{"results":[{"label":"web","breakdown_value":["web"],"data":[3,4],"labels":["25-Nov","26-Nov"],"days":["2026-11-25","2026-11-26"],"count":7},{"label":"ios","breakdown_value":["ios"],"data":[1,0],"labels":["25-Nov","26-Nov"],"count":1}]}"#), at: now)
        #expect(lines.shape(for: daily) == .bars(labels: ["25-Nov", "26-Nov"], series: [.init(name: "web", values: [3, 4]), .init(name: "ios", values: [1, 0])]))

        var pie = trend
        pie.display = "ActionsPie"
        #expect(lines.shape(for: pie) == .split([.init(name: "web", value: 7), .init(name: "ios", value: 1)]))
    }

    @Test func tableResultsDrawByTheirChartSettings() {
        let now = Date(timeIntervalSince1970: 0)
        let detail = DashboardReading.detail(appDashboard, ref: ref)
        let total = InsightResult.parse(json(#"{"columns":["total"],"results":[[1053]]}"#), at: now)
        #expect(total.shape(for: detail.tiles[0]) == .numbers([.init(name: "total", value: 1053)]))
        #expect(total.numbers(for: detail.tiles[0]).first?.value == 1053)

        let stacked = InsightResult.parse(json(#"{"columns":["day","ios","android"],"results":[["2026-11-25",66,150],["2026-11-26",24,26]]}"#), at: now)
        #expect(stacked.shape(for: detail.tiles[2]) == .bars(labels: ["2026-11-25", "2026-11-26"], series: [.init(name: "ios", values: [66, 24]), .init(name: "android", values: [150, 26])]))

        let table = InsightResult.parse(json(#"{"columns":["version","platform","crashed"],"results":[["1.0.4","ios",0],["1.0.3","android",null]]}"#), at: now)
        #expect(table.shape(for: detail.tiles[3]) == .table(columns: ["version", "platform", "crashed"], rows: [["1.0.4", "ios", "0"], ["1.0.3", "android", "–"]]))
        let row = InsightResult.parse(json(#"{"columns":["viewed","tapped"],"results":[[238,12]]}"#), at: now)
        #expect(row.shape(for: detail.tiles[3]) == .numbers([.init(name: "viewed", value: 238), .init(name: "tapped", value: 12)]))
    }
}
