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
        #expect(read.needsHourlyRead([.revenueLast28Days], at: day.addingTimeInterval(600)), "newly shown, never read")
        #expect(!read.needsHourlyRead([.activeWeek, .totalUsers], at: day.addingTimeInterval(600)), "the week and the total are read on every refresh")
        #expect(!read.needsHourlyRead([.newUsers], at: day.addingTimeInterval(7200)), "nothing hourly is shown")

        // A refresh that skipped the hourly read keeps the last values, even across midnight.
        let next = ProjectSnapshot(projectId: id, fetchedAt: day, dayStart: day.addingTimeInterval(86_400), values: [.newUsers: 1])
        let merged = next.fillingGaps(from: read)
        #expect(merged[.activeMonth] == 900)
        #expect(merged.newUsers == 1)
        #expect(merged.hourlyReadAt == day)
    }

    @Test func numbersFollowTheCountingTheyWereReadUnder() throws {
        let id = UUID()
        let day = Date(timeIntervalSince1970: 1_000_000)
        let settings = MetricSettings(newUsers: .firstSeen, revenue: .revenueCat, excludedSurfaces: [.visitors])
        let everyone = settings.leaving(out: [])
        let read = ProjectSnapshot(projectId: id, fetchedAt: day, dayStart: day, values: [.activeMonth: 1233, .mrr: 86, .newUsers: 4], hourlyReadAt: day, countedAs: everyone)
        // Shown for the settings it was read under; under others only what does not follow counting.
        #expect(read.values(countedAs: everyone) == read.values)
        #expect(read.values(countedAs: settings) == [.mrr: 86])
        // A refresh under the new scope keeps the hourly MRR, not the old monthly actives or their read time.
        let next = ProjectSnapshot(projectId: id, fetchedAt: day, dayStart: day, values: [.newUsers: 3], countedAs: settings)
        let merged = next.fillingGaps(from: read)
        #expect(merged.values == [.newUsers: 3, .mrr: 86])
        #expect(merged.hourlyReadAt == nil)
        #expect(try JSONDecoder().decode(ProjectSnapshot.self, from: JSONEncoder().encode(read)) == read)
        // Settings saved before scopes existed are in effect with visitors left out.
        #expect(MetricSettings(newUsers: .firstSeen, revenue: .revenueCat).inEffect == settings)
    }

    @Test func savedValuesRoundTripByMetricId() throws {
        let day = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = ProjectSnapshot(projectId: UUID(), fetchedAt: day, dayStart: day, values: [.newUsers: 4, .event("paid wall", people: true): 2, .mrr: 87.5])
        let data = try JSONEncoder().encode(snapshot)
        #expect(String(decoding: data, as: UTF8.self).contains(#""event_people:paid wall":2"#))
        #expect(try JSONDecoder().decode(ProjectSnapshot.self, from: data) == snapshot)
        // A cache written before metrics had ids reads as empty, not as a failure; a tally from before platforms is dropped.
        let legacy = #"{"projectId":"\#(snapshot.projectId)","fetchedAt":0,"dayStart":0,"newUsers":4,"hourlyNewUsers":[],"failures":[],"userTally":{"people":9,"before":0}}"#
        let decoded = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(legacy.utf8))
        #expect(decoded.values.isEmpty && decoded.userTally == nil && decoded.previous.isEmpty)
    }

    @Test func cardsFromBeforeTheRedesignStartWithTheStandardCard() throws {
        let account = UUID()
        var base = Project(name: "Old", tint: .ink, posthog: PostHogLink(accountId: account, projectId: 1, projectName: "x", timeZone: "UTC"), appStore: AppStoreLink(accountId: account, appId: "1", appName: "x", bundleId: "b"))
        base.card = CardLayout(big: [.mrr], rows: [[.online]], trend: false, split: true)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        // A card this version saved keeps everything, the switches included.
        #expect(try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json)) == base)
        // One saved before (no version) and one from before cards were customizable start over.
        json["card"] = ["big": ["new_users"], "small": ["revenue", "event_count:Application Installed"]]
        #expect(try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json)).card == CardLayout.standard(for: base))
        json["card"] = nil
        #expect(try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json)).card == CardLayout(big: [.totalUsers], rows: [[.activeToday, .activeWeek, .newWeek]]))
    }

    @Test func cardsKeepTheirRowWhenRowsArrive() throws {
        // A card saved with one row under `small` reads as its first row; rows are saved as rows.
        let saved = #"{"big":["total_users"],"small":["active_today","mrr"],"trend":true,"split":false,"v":2}"#
        let layout = try JSONDecoder().decode(CardLayout.self, from: Data(saved.utf8))
        #expect(layout == CardLayout(big: [.totalUsers], rows: [[.activeToday, .mrr]], split: false))
        let two = CardLayout(big: [.totalUsers], rows: [[.activeToday], [.mrr, .revenue]])
        #expect(try JSONDecoder().decode(CardLayout.self, from: JSONEncoder().encode(two)) == two)
        // Repeats, empty rows, a fourth number in a row and a third row are dropped.
        let crowded = CardLayout(big: [.mrr], rows: [[], [.mrr, .online, .revenue, .orders, .pageviews], [.online, .newUsers], [.activeMonth]])
        #expect(crowded.rows == [[.online, .revenue, .orders], [.newUsers]])
    }

    @Test func numbersTradePlacesAndMoveToOpenings() throws {
        let layout = CardLayout(big: [.totalUsers], rows: [[.activeToday, .activeWeek, .newWeek]])
        #expect(layout.openings == [.add(row: 1)], "a full row has no room; a second row can start")
        // A small number dropped on the big one trades places with it.
        #expect(layout.moving(from: .small(row: 0, index: 2), to: .big(0)) == CardLayout(big: [.newWeek], rows: [[.activeToday, .activeWeek, .totalUsers]]))
        // Dropped on the new row, it leaves its row and starts the next.
        let moved = try #require(layout.moving(from: .small(row: 0, index: 0), to: .add(row: 1)))
        #expect(moved.rows == [[.activeWeek, .newWeek], [.activeToday]])
        #expect(moved.openings == [.add(row: 0), .add(row: 1)])
        // The last number of a row leaving it closes the row.
        #expect(moved.moving(from: .small(row: 1, index: 0), to: .add(row: 0))?.rows == [[.activeWeek, .newWeek, .activeToday]])
        // The only big number cannot leave; one of two can.
        #expect(moved.moving(from: .big(0), to: .add(row: 1)) == nil)
        let twoBig = CardLayout(big: [.totalUsers, .mrr], rows: [[.activeToday]])
        #expect(twoBig.moving(from: .big(1), to: .add(row: 0)) == CardLayout(big: [.totalUsers], rows: [[.activeToday, .mrr]]))
        #expect(twoBig.moving(from: .big(1), to: .add(row: 2)) == nil, "only the next row can start")
        #expect(twoBig.removing(.big(1)) == CardLayout(big: [.totalUsers], rows: [[.activeToday]]))
        #expect(twoBig.removing(.big(0)).removing(.big(0)).big == [.mrr], "the last big number stays")
        // From the library: a number on the card swaps or moves; a new one replaces or is added.
        #expect(layout.placing(.totalUsers, at: .small(row: 0, index: 1)) == CardLayout(big: [.activeWeek], rows: [[.activeToday, .totalUsers, .newWeek]]))
        #expect(layout.placing(.mrr, at: .add(row: 1)).rows == [[.activeToday, .activeWeek, .newWeek], [.mrr]])
        #expect(layout.placing(.mrr, at: .small(row: 0, index: 0)).rows == [[.mrr, .activeWeek, .newWeek]])
        #expect(layout.placing(.mrr, at: .add(row: 0)) == layout, "a full row takes no more")
        #expect(moved.slots == [.big(0), .small(row: 0, index: 0), .small(row: 0, index: 1), .small(row: 1, index: 0)])
    }

    @Test func cardsLeaveOutNumbersTheProjectCannotRead() {
        let account = UUID()
        let storeOnly = Project(name: "Store", tint: .ink, appStore: AppStoreLink(accountId: account, appId: "1", appName: "x", bundleId: "b"))
        #expect(storeOnly.card == CardLayout(big: [.reviewsToAnswer]))
        let layout = CardLayout(big: [.activeToday, .mrr], rows: [[.revenue, .reviewsToAnswer, .reviewsToAnswer]])
        #expect(layout.visible(in: storeOnly) == CardLayout(big: [.reviewsToAnswer], trend: false, split: false), "a small number takes the empty big slot; bars and split need PostHog")
        #expect(Set(Metric.fixed.map(\.id)).count == Metric.fixed.count)
        #expect(Metric.fixed.allSatisfy { Metric(id: $0.id) == $0 })
        #expect(Metric(id: "event_count:a:b") == .event("a:b", people: false))
        #expect(Metric(id: "nope") == nil)
    }

    @Test func settingsKeepEarlierChoicesWhenNewOnesAreAdded() throws {
        let saved = #"{"demoMode":true,"theme":"dark","accent":"mint","haptics":false,"sound":true,"refreshOnOpen":false,"replyTone":"brief","replySignature":"— Liu"}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(saved.utf8))
        #expect(settings.theme == .dark && settings.accent == .mint && settings.replySignature == "— Liu")
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func rateWithNothingToShowWaitsForTheHourLikeTheRest() throws {
        let id = UUID()
        let day = Date(timeIntervalSince1970: 1_000_000)
        // Google had no crash rate for a small app: read, but nothing to show.
        let read = ProjectSnapshot(projectId: id, fetchedAt: day, dayStart: day, values: [.mrr: 87], hourlyReadAt: day, hourlyRead: [.mrr, .crashRate])
        #expect(!read.needsHourlyRead([.mrr, .crashRate], at: day.addingTimeInterval(600)))
        #expect(read.needsHourlyRead([.anrRate], at: day.addingTimeInterval(600)), "never read")
        #expect(read.fillingGaps(from: nil).hourlyRead == [.mrr, .crashRate])

        let decoded = try JSONDecoder().decode(ProjectSnapshot.self, from: JSONEncoder().encode(read))
        #expect(decoded.hourlyRead == [.mrr, .crashRate])
        // Caches from before it was recorded count the hourly numbers they hold as read.
        let old = #"{"projectId":"\#(id)","fetchedAt":0,"dayStart":0,"values":{"active_month":900,"new_users":4},"hourlyReadAt":0}"#
        #expect(try JSONDecoder().decode(ProjectSnapshot.self, from: Data(old.utf8)).hourlyRead == [.activeMonth])
    }

    @Test func playReviewsAreKeptAfterGoogleStopsReturningThem() {
        let account = UUID()
        var project = Project(name: "Atlas", tint: .ink, appStore: AppStoreLink(accountId: account, appId: "1", appName: "Atlas", bundleId: "com.example.atlas"), googlePlay: GooglePlayLink(accountId: account, packageName: "com.example.atlas"))
        let day = Date(timeIntervalSince1970: 1_000_000)
        func review(_ id: String, _ platform: Platform, hoursAgo: Double, replied: Bool = false) -> Review {
            Review(storeId: id, platform: platform, projectId: project.id, rating: 3, body: id, createdAt: day.addingTimeInterval(-hoursAgo * 3600),
                   reply: replied ? ReviewReply(text: "Thanks", date: day, pending: false) : nil)
        }
        func result(_ reviews: [Platform: [Review]]) -> RefreshResult {
            RefreshResult(snapshot: ProjectSnapshot(projectId: project.id, fetchedAt: day, dayStart: day), reviews: reviews)
        }
        var cache = RefreshCache()
        cache.land(result([.appStore: [review("a1", .appStore, hoursAgo: 1)], .googlePlay: [review("g1", .googlePlay, hoursAgo: 200), review("g2", .googlePlay, hoursAgo: 2)]]), for: project)

        // A week on, Google returns only the new one and g2 replied; g1 stays, App Store is replaced.
        let snapshot = cache.land(result([.appStore: [review("a2", .appStore, hoursAgo: 1)], .googlePlay: [review("g2", .googlePlay, hoursAgo: 2, replied: true), review("g3", .googlePlay, hoursAgo: 1)]]), for: project)
        #expect(Set(cache.reviews[project.id]!.map(\.storeId)) == ["a2", "g1", "g2", "g3"])
        #expect(cache.reviews[project.id]!.filter { $0.storeId == "g2" }.count == 1)
        #expect(snapshot.reviewsToAnswer == 3, "a2, g1 and g3")
        #expect(cache.snapshots[project.id]?.reviewsToAnswer == 3)

        // A store that fails keeps its reviews; the count covers what is kept.
        let failed = cache.land(result([.appStore: []]), for: project)
        #expect(Set(cache.reviews[project.id]!.map(\.storeId)) == ["g1", "g2", "g3"])
        #expect(failed.reviewsToAnswer == 2)

        // Disconnected, its reviews go.
        project.googlePlay = nil
        cache.land(result([.appStore: []]), for: project)
        #expect(cache.reviews[project.id] == nil)
    }

    @Test func playHistoryKeepsTheNewestUpToTheLimit() {
        let project = Project(name: "Busy", tint: .ink, googlePlay: GooglePlayLink(accountId: UUID(), packageName: "com.example.busy"))
        let day = Date(timeIntervalSince1970: 1_000_000)
        func page(_ range: Range<Int>) -> [Review] {
            range.map { Review(storeId: "g\($0)", platform: .googlePlay, projectId: project.id, rating: 5, body: "", createdAt: day.addingTimeInterval(Double($0))) }
        }
        var cache = RefreshCache()
        cache.land(RefreshResult(snapshot: ProjectSnapshot(projectId: project.id, fetchedAt: day, dayStart: day), reviews: [.googlePlay: page(0..<400)]), for: project)
        cache.land(RefreshResult(snapshot: ProjectSnapshot(projectId: project.id, fetchedAt: day, dayStart: day), reviews: [.googlePlay: page(400..<700)]), for: project)
        let kept = cache.reviews[project.id]!
        #expect(kept.count == GooglePlayClient.reviewLimit)
        #expect(kept.map(\.storeId).contains("g699") && !kept.map(\.storeId).contains("g199"))
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
