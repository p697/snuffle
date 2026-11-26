import SnuffleKit
import XCTest
@testable import Snuffle

/// What each number is set against, and finding the dashboard's own number beside it.
@MainActor
final class ReferenceTests: XCTestCase {
    private func snapshot(_ values: [Metric: Double], previous: [Metric: Double]) -> ProjectSnapshot {
        ProjectSnapshot(projectId: UUID(), fetchedAt: .now, dayStart: .now, values: values, previous: previous)
    }

    func testEachNumberReadsAgainstItsOwnReference() {
        let numbers = snapshot([.totalUsers: 1053, .activeToday: 50, .activeWeek: 531, .newWeek: 287],
                               previous: [.totalUsers: 1047, .activeToday: 54, .activeWeek: 440, .newWeek: 287])
        XCTAssertEqual(Metric.totalUsers.reference(in: numbers)?.text, String(localized: "今天 \(Format.delta(users: 6))"))
        XCTAssertEqual(Metric.activeToday.reference(in: numbers)?.text, String(localized: "昨天此时 \(Format.number(54))"))
        XCTAssertEqual(Metric.activeToday.reference(in: numbers)?.tone, .muted)
        // A narrow column reads today against yesterday as a change.
        XCTAssertEqual(Metric.activeToday.reference(in: numbers, compact: true)?.tone, .down)
        XCTAssertEqual(Metric.activeWeek.reference(in: numbers)?.text, "▲ " + Format.percent(91.0 / 440))
        XCTAssertEqual(Metric.activeWeek.reference(in: numbers)?.tone, .up)
        XCTAssertEqual(Metric.newWeek.reference(in: numbers)?.tone, .muted, "unchanged")
        XCTAssertNil(Metric.revenue.reference(in: numbers))
        XCTAssertNil(Metric.change(5, from: 0), "nothing to compare with")
    }

    func testDashboardNumbersMatchExactlyOrWithinAPercentForLargeOnes() {
        let numbers = [
            DashboardNumber(chart: "Total installations", value: 1053),
            DashboardNumber(chart: "Active installations", value: 531, previous: 440),
            DashboardNumber(chart: "DAU", value: 22_061)
        ]
        XCTAssertEqual(DashboardNumber.match(531, in: numbers)?.number.chart, "Active installations")
        XCTAssertEqual(DashboardNumber.match(531, in: numbers)?.exact, true)
        // Read a moment apart, a growing number may be one or two ahead.
        XCTAssertEqual(DashboardNumber.match(22_070, in: numbers)?.exact, false)
        XCTAssertEqual(DashboardNumber.match(1054, in: numbers)?.number.chart, "Total installations")
        // Small numbers only match exactly: 50 is not 49.
        XCTAssertNil(DashboardNumber.match(49, in: [DashboardNumber(chart: "DAU", value: 50)]))
        XCTAssertNil(DashboardNumber.match(nil, in: numbers))
    }

    func testInstallCountingNamesInstalls() {
        var project = Project(name: "App", tint: .ink, posthog: PostHogLink(accountId: UUID(), projectId: 1, projectName: "App", timeZone: "UTC"))
        project.metrics = MetricSettings(newUsers: .firstSeen, revenue: .none, unit: .install)
        XCTAssertEqual(Metric.totalUsers.title(in: project), String(localized: "累计安装"))
        XCTAssertEqual(Metric.newUsers.title(in: project), String(localized: "新增安装"))
        XCTAssertEqual(Metric.activeWeek.title(in: project), Metric.activeWeek.title)
        project.metrics.unit = .person
        XCTAssertEqual(Metric.totalUsers.title(in: project), Metric.totalUsers.title)
    }
}
