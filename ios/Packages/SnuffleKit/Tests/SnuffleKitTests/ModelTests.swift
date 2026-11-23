import Foundation
import Testing
@testable import SnuffleKit

@Suite("Clock and deltas")
struct ModelTests {
    @Test func todayFollowsTheProjectTimeZone() {
        // 2026-11-20 17:32 in Shanghai is 09:32 UTC.
        let now = ISO8601.parse("2026-11-20T09:32:00Z")!
        let clock = ProjectClock(now: now, timeZoneIdentifier: "Asia/Shanghai")
        #expect(clock.todayStart == ISO8601.parse("2026-11-19T16:00:00Z"))
        #expect(clock.yesterdayStart == ISO8601.parse("2026-11-18T16:00:00Z"))
        #expect(clock.sameTimeYesterday == ISO8601.parse("2026-11-19T09:32:00Z"))
        #expect(clock.hoursSoFar == 18)
        #expect(clock.dayKey(now) == "2026-11-20")
    }

    @Test func sameTimeYesterdayKeepsWallClockAcrossDaylightSaving() {
        // New York falls back on 2026-11-01; 10:00 local on Nov 2 is 15:00 UTC, and 10:00 local on Nov 1 is also 15:00 UTC.
        let now = ISO8601.parse("2026-11-02T15:00:00Z")!
        let clock = ProjectClock(now: now, timeZoneIdentifier: "America/New_York")
        #expect(clock.sameTimeYesterday == ISO8601.parse("2026-11-01T15:00:00Z"))
        #expect(clock.dayStarts(days: 3).map(clock.dayKey) == ["2026-10-31", "2026-11-01", "2026-11-02"])
    }

    @Test func unknownTimeZoneFallsBackToThePhone() {
        let clock = ProjectClock(now: Date(), timeZoneIdentifier: "Not/AZone")
        #expect(clock.timeZone == .current)
    }

    @Test func changeCountsOnlyWhatWentUpOnTheSameDay() {
        let id = UUID()
        let day = Date(timeIntervalSince1970: 1_000_000)
        let shown: [Metric] = [.newUsers, .revenue, .orders, .reviewsToAnswer, .online, .activeToday]
        let old = ProjectSnapshot(projectId: id, fetchedAt: day, dayStart: day, values: [.newUsers: 10, .revenue: 20, .orders: 1, .online: 3, .activeToday: 50])
        var new = old
        new[.newUsers] = 13
        new[.revenue] = 60
        new[.orders] = 2
        new[.online] = 9
        new[.activeToday] = 70
        let change = SnapshotChange(from: old, to: new, metrics: shown)
        #expect(change.rises == [.newUsers: 3, .revenue: 40, .orders: 1, .activeToday: 20], "people online come and go: never marked")
        #expect(change.isUp && change.hasSale)
        #expect(SnapshotChange(from: old, to: new, metrics: [.activeToday]).rises == [.activeToday: 20], "only what is shown")

        var withPrevious = old
        withPrevious[.reviewsToAnswer] = 1
        var newReview = withPrevious
        newReview[.reviewsToAnswer] = 2
        let reviewChange = SnapshotChange(from: withPrevious, to: newReview, metrics: shown)
        #expect(reviewChange[.reviewsToAnswer] == 1 && reviewChange.isNews && !reviewChange.isUp)

        var shrunk = old
        shrunk[.newUsers] = 8
        #expect(SnapshotChange(from: old, to: shrunk, metrics: shown) == .none)

        var tomorrow = new
        tomorrow.dayStart = day.addingTimeInterval(86_400)
        #expect(SnapshotChange(from: old, to: tomorrow, metrics: shown) == .none)
        #expect(SnapshotChange(from: nil, to: new, metrics: shown) == .none)

        var total = SnapshotChange.none
        total.add(change)
        total.add(SnapshotChange(rises: [.newUsers: 2]))
        #expect(total[.newUsers] == 5)
    }

    @Test func failedSourceKeepsLastKnownValuesForTheSameDay() {
        let id = UUID()
        let day = Date(timeIntervalSince1970: 1_000_000)
        let previous = ProjectSnapshot(projectId: id, fetchedAt: day, dayStart: day, values: [.newUsers: 10, .revenue: 3.28, .reviewsToAnswer: 6], revenueSource: .revenueCat)
        let partial = ProjectSnapshot(projectId: id, fetchedAt: day, dayStart: day, values: [.newUsers: 12], failures: [SourceFailure(platform: .revenueCat, message: "x")])
        let merged = partial.fillingGaps(from: previous)
        #expect(merged.newUsers == 12)
        #expect(merged.revenue == 3.28)
        #expect(merged.reviewsToAnswer == 6)

        var nextDay = partial
        nextDay.dayStart = day.addingTimeInterval(86_400)
        #expect(nextDay.fillingGaps(from: previous).revenue == nil)
    }

    @Test func hourlyMetricsAreReadOnceAnHourAndKeptBetween() {
        let id = UUID()
        let day = Date(timeIntervalSince1970: 1_000_000)
        let read = ProjectSnapshot(projectId: id, fetchedAt: day, dayStart: day, values: [.activeMonth: 900, .newUsers: 4], hourlyReadAt: day)
        #expect(!read.needsHourlyRead([.activeMonth, .newUsers], at: day.addingTimeInterval(600)))
        #expect(read.needsHourlyRead([.activeMonth], at: day.addingTimeInterval(3600)), "an hour later")
        #expect(read.needsHourlyRead([.activeWeek], at: day.addingTimeInterval(600)), "newly shown, never read")
        #expect(!read.needsHourlyRead([.newUsers], at: day.addingTimeInterval(7200)), "nothing hourly is shown")

        // A refresh that skipped the hourly read keeps the last values, even across midnight.
        let next = ProjectSnapshot(projectId: id, fetchedAt: day, dayStart: day.addingTimeInterval(86_400), values: [.newUsers: 1])
        let merged = next.fillingGaps(from: read)
        #expect(merged[.activeMonth] == 900)
        #expect(merged.newUsers == 1)
        #expect(merged.hourlyReadAt == day)
    }

    @Test func savedValuesRoundTripByMetricId() throws {
        let day = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = ProjectSnapshot(projectId: UUID(), fetchedAt: day, dayStart: day, values: [.newUsers: 4, .event("paid wall", people: true): 2, .mrr: 87.5])
        let data = try JSONEncoder().encode(snapshot)
        #expect(String(decoding: data, as: UTF8.self).contains(#""event_people:paid wall":2"#))
        #expect(try JSONDecoder().decode(ProjectSnapshot.self, from: data) == snapshot)
        // A cache written before metrics had ids reads as empty, not as a failure.
        let legacy = #"{"projectId":"\#(snapshot.projectId)","fetchedAt":0,"dayStart":0,"newUsers":4,"hourlyNewUsers":[],"failures":[]}"#
        #expect(try JSONDecoder().decode(ProjectSnapshot.self, from: Data(legacy.utf8)).values.isEmpty)
    }

    @Test func projectsSavedBeforeCardLayoutsKeepTheirNumbers() throws {
        let account = UUID()
        let base = Project(name: "Old", tint: .ink, posthog: PostHogLink(accountId: account, projectId: 1, projectName: "x", timeZone: "UTC"), appStore: AppStoreLink(accountId: account, appId: "1", appName: "x", bundleId: "b"))
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        json["card"] = nil
        json["metrics"] = ["newUsers": ["firstSeen": [:]], "revenue": ["posthogEvent": ["event": "purchase", "valueProperty": "value"]], "extra": ["event": ["name": "paywall_viewed", "label": "次付费墙浏览"]]]
        let old = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.metrics == MetricSettings(newUsers: .firstSeen, revenue: .posthogEvent(event: "purchase", valueProperty: "value")))
        #expect(old.card == CardLayout(big: [.newUsers], small: [.revenue, .event("paywall_viewed", people: false), .reviewsToAnswer]))
        #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(old)) == old)
    }

    @Test func cardsLeaveOutNumbersTheProjectCannotRead() {
        let account = UUID()
        let storeOnly = Project(name: "Store", tint: .ink, appStore: AppStoreLink(accountId: account, appId: "1", appName: "x", bundleId: "b"))
        #expect(storeOnly.card == CardLayout(big: [.reviewsToAnswer]))
        let layout = CardLayout(big: [.activeToday, .mrr], small: [.revenue, .reviewsToAnswer, .reviewsToAnswer])
        #expect(layout.visible(in: storeOnly) == CardLayout(big: [.reviewsToAnswer]), "a pill takes the empty big slot")
        #expect(Set(Metric.fixed.map(\.id)).count == Metric.fixed.count)
        #expect(Metric.fixed.allSatisfy { Metric(id: $0.id) == $0 })
        #expect(Metric(id: "event_count:a:b") == .event("a:b", people: false))
        #expect(Metric(id: "nope") == nil)
    }

    @Test func settingsKeepEarlierChoicesWhenNewOnesAreAdded() throws {
        let saved = #"{"demoMode":true,"theme":"dark","accent":"mint","haptics":false,"sound":true,"refreshOnOpen":false,"replyTone":"brief","replySignature":"— Liu"}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(saved.utf8))
        #expect(settings.theme == .dark && settings.accent == .mint && settings.replySignature == "— Liu")
        #expect(settings.totals == CardLayout.standardTotals)
        var changed = settings
        changed.totals = [.activeToday, .mrr, .newUsers]
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(changed)).totals == [.activeToday, .mrr, .newUsers])
    }

    @Test func refreshCountStartsOverEachDay() {
        var cache = RefreshCache()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let morning = ISO8601.parse("2026-11-20T08:00:00Z")!
        cache.recordRefresh(at: morning, calendar: calendar)
        cache.recordRefresh(at: morning.addingTimeInterval(600), calendar: calendar)
        #expect(cache.refreshCountToday == 2)
        cache.recordRefresh(at: morning.addingTimeInterval(86_400), calendar: calendar)
        #expect(cache.refreshCountToday == 1)
    }

    @Test func workspaceFindsProjectsThatDependOnAnAccount() {
        let account = Account(platform: .posthog, title: "a", subtitle: "b")
        let using = Project(name: "Uses", tint: .ink, posthog: PostHogLink(accountId: account.id, projectId: 1, projectName: "x", timeZone: "UTC"))
        let other = Project(name: "Other", tint: .ink)
        let workspace = Workspace(projects: [using, other], accounts: [account])
        #expect(workspace.projects(using: account.id).map(\.name) == ["Uses"])
    }
}
