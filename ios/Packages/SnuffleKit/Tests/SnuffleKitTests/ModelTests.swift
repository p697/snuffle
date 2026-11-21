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
        let old = ProjectSnapshot(projectId: id, fetchedAt: day, dayStart: day, newUsers: 10, revenue: 20, sales: 1)
        var new = old
        new.newUsers = 13
        new.revenue = 60
        new.sales = 2
        let change = SnapshotChange(from: old, to: new)
        #expect(change == SnapshotChange(newUsers: 3, revenue: 40, sales: 1))
        #expect(change.isUp && change.hasSale)

        var newReview = old
        newReview.reviewsToAnswer = 2
        var withPrevious = old
        withPrevious.reviewsToAnswer = 1
        let reviewChange = SnapshotChange(from: withPrevious, to: newReview)
        #expect(reviewChange.reviews == 1 && reviewChange.isNews && !reviewChange.isUp)

        var shrunk = old
        shrunk.newUsers = 8
        #expect(SnapshotChange(from: old, to: shrunk) == .none)

        var tomorrow = new
        tomorrow.dayStart = day.addingTimeInterval(86_400)
        #expect(SnapshotChange(from: old, to: tomorrow) == .none)
        #expect(SnapshotChange(from: nil, to: new) == .none)
    }

    @Test func failedSourceKeepsLastKnownValuesForTheSameDay() {
        let id = UUID()
        let day = Date(timeIntervalSince1970: 1_000_000)
        let previous = ProjectSnapshot(projectId: id, fetchedAt: day, dayStart: day, newUsers: 10, revenue: 3.28, revenueSource: .revenueCat, reviewsToAnswer: 6)
        let partial = ProjectSnapshot(projectId: id, fetchedAt: day, dayStart: day, newUsers: 12, failures: [SourceFailure(platform: .revenueCat, message: "x")])
        let merged = partial.fillingGaps(from: previous)
        #expect(merged.newUsers == 12)
        #expect(merged.revenue == 3.28)
        #expect(merged.reviewsToAnswer == 6)

        var nextDay = partial
        nextDay.dayStart = day.addingTimeInterval(86_400)
        #expect(nextDay.fillingGaps(from: previous).revenue == nil)
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
