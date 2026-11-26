import Foundation
import Testing
@testable import SnuffleKit

@Suite("Demo world")
struct DemoTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    let afternoon = ISO8601.parse("2026-11-20T15:00:00Z")!
    let lumen = DemoWorld.projects[0]
    let ferry = DemoWorld.projects[1]
    let atlas = DemoWorld.projects[2]

    @Test func newDayStartsProportionalToTheHour() {
        var random = SplitMix64(seed: 1)
        let world = DemoWorld.make(now: afternoon, calendar: calendar, random: &random)
        let lumen = world.snapshot(for: self.lumen)!
        // 15:00 is 62.5% of the day: about 4120 × 1.18 × 0.625 new users.
        #expect((2900...3200).contains(lumen.newUsers!))
        // Every number is set against something, and the card's bars end with today.
        #expect(lumen.previous[.activeToday] != nil && lumen.previous[.activeWeek] != nil && lumen.previous[.newWeek] != nil)
        #expect(lumen.dailyActive.count == PostHogQueries.recentDays)
        #expect(lumen.dailyActive.last == lumen[.activeToday].map(Int.init))
        #expect(lumen.platforms.map(\.count).reduce(0, +) - Int(lumen[.totalUsers]!) <= lumen.platforms.count)
        #expect(lumen.platforms.first?.name == Surface.web.rawValue)
        #expect(lumen.revenueSource == .posthog)
        #expect(lumen.reviewsToAnswer == 5)
        let ferry = world.snapshot(for: self.ferry)!
        #expect(ferry.revenue == 3.28)
        #expect(ferry.orders == nil)
        #expect(ferry[.mrr] == 87)
        // Every number on the demo cards has a value.
        for project in DemoWorld.projects {
            let snapshot = world.snapshot(for: project)!
            #expect(project.card.metrics.allSatisfy { snapshot[$0] != nil }, "\(project.name)")
        }
        #expect(world.eventStats(for: DemoWorld.lumenId).first?.name == "$pageview")
    }

    @Test func lateInDayFillsTheDayButKeepsReviewsInThePast() {
        var random = SplitMix64(seed: 4)
        let night = ISO8601.parse("2026-11-20T01:30:00Z")!
        let world = DemoWorld.make(now: night, calendar: calendar, lateInDay: true, random: &random)
        #expect(world.simulatedNow == ISO8601.parse("2026-11-20T21:30:00Z")!)
        #expect(world.snapshot(for: lumen)!.dailyActive.count == PostHogQueries.recentDays)
        #expect(world.reviews.allSatisfy { $0.createdAt < night })
    }

    @Test func advancingAddsUsersAndNeverGoesBackInTime() {
        var random = SplitMix64(seed: 2)
        var world = DemoWorld.make(now: afternoon, calendar: calendar, random: &random)
        let before = world.snapshot(for: lumen)!
        world.advance(to: afternoon, calendar: calendar, random: &random)
        let after = world.snapshot(for: lumen)!
        #expect(after.newUsers! > before.newUsers!)
        #expect(after.fetchedAt > before.fetchedAt)
        #expect(SnapshotChange(from: before, to: after, metrics: [.newUsers]).isUp)
    }

    @Test func scenariosShapeTheNextRefresh() {
        var random = SplitMix64(seed: 3)
        var world = DemoWorld.make(now: afternoon, calendar: calendar, random: &random)

        world.scenario = .quiet
        let quietBefore = world.snapshot(for: lumen)!
        world.advance(to: afternoon, calendar: calendar, random: &random)
        #expect(SnapshotChange(from: quietBefore, to: world.snapshot(for: lumen)!, metrics: lumen.card.metrics) == .none)

        world.scenario = .sale
        let saleBefore = world.snapshot(for: lumen)!
        world.advance(to: afternoon, calendar: calendar, random: &random)
        let saleAfter = world.snapshot(for: lumen)!
        #expect(saleAfter.orders == saleBefore.orders! + 1)
        #expect(SnapshotChange(from: saleBefore, to: saleAfter, metrics: lumen.card.metrics).hasSale)

        world.scenario = .failure
        #expect(world.snapshot(for: ferry)!.failures.map(\.platform) == [.revenueCat])
        #expect(world.snapshot(for: lumen)!.failures.isEmpty)
    }

    @Test func midnightStartsAFreshDayAndKeepsTheScenario() {
        var random = SplitMix64(seed: 4)
        var world = DemoWorld.make(now: afternoon, calendar: calendar, random: &random)
        world.scenario = .sale
        let tomorrow = afternoon.addingTimeInterval(86_400)
        world.advance(to: tomorrow, calendar: calendar, random: &random)
        #expect(world.dayStart == calendar.startOfDay(for: tomorrow))
        #expect(world.scenario == .sale)
    }

    @Test func replyingMarksTheReviewAnswered() {
        var random = SplitMix64(seed: 5)
        var world = DemoWorld.make(now: afternoon, calendar: calendar, random: &random)
        let review = world.reviews.first { $0.needsReply && $0.platform == .appStore }!
        world.markReplied(review.id, text: "Thanks!", at: afternoon)
        let updated = world.reviews.first { $0.id == review.id }!
        #expect(updated.reply?.pending == true)
        #expect(world.snapshot(for: DemoWorld.projects.first { $0.id == review.projectId }!)!.reviewsToAnswer == world.reviews.filter { $0.projectId == review.projectId && $0.needsReply }.count)
    }

    @Test func boardIsStableAndEndsWithToday() {
        var random = SplitMix64(seed: 6)
        let world = DemoWorld.make(now: afternoon, calendar: calendar, random: &random)
        let first = world.board(for: DemoWorld.lumenId, days: 30, total: ["web": 900, "ios": 400], calendar: calendar)
        let second = world.board(for: DemoWorld.lumenId, days: 30, total: ["web": 900, "ios": 400], calendar: calendar)
        #expect(first == second)
        #expect(first.days.count == 30)
        #expect(first.weeks.count == 11)
        // The last day's total is today's; earlier ones take away the people new after them.
        #expect(first.days.last?.total == ["web": 900, "ios": 400])
        #expect((first.days[28].total["web"] ?? 0) == 900 - (first.days[29].new["web"] ?? 0))
        #expect(world.board(for: DemoWorld.atlasId, days: 7, total: nil, calendar: calendar).days.allSatisfy { $0.revenue == nil })
    }

    @Test func poissonStaysNearItsMean() {
        var random = SplitMix64(seed: 7)
        let small = (0..<2000).map { _ in DemoWorld.poisson(2, random: &random) }
        let big = (0..<2000).map { _ in DemoWorld.poisson(50, random: &random) }
        #expect(abs(Double(small.reduce(0, +)) / 2000 - 2) < 0.2)
        #expect(abs(Double(big.reduce(0, +)) / 2000 - 50) < 1.5)
        #expect(DemoWorld.poisson(0, random: &random) == 0)
    }

    @Test func providerPersistsEveryChange() async throws {
        let saved = Saved()
        let provider = DemoProvider(world: nil, latency: .zero) { saved.world = $0 }
        await provider.setScenario(.sale)
        await provider.advance()
        #expect(saved.world?.scenario == .sale)
        let lumen = DemoWorld.projects[0]
        let result = await provider.refresh(lumen, metrics: Set(lumen.card.metrics), previous: nil)
        #expect(result.reviews.keys.sorted { $0.rawValue < $1.rawValue } == [.appStore, .googlePlay])
        let review = try #require(result.reviews.values.joined().first { $0.needsReply })
        try await provider.reply(to: review, text: "Thank you", in: lumen)
        #expect(saved.world?.reviews.first { $0.id == review.id }?.reply?.text == "Thank you")
    }
}

final class Saved: @unchecked Sendable {
    var world: DemoWorld?
}
