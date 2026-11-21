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

    @Test func newDayStartsProportionalToTheHour() {
        var random = SplitMix64(seed: 1)
        let world = DemoWorld.make(now: afternoon, calendar: calendar, random: &random)
        let lumen = world.snapshot(for: DemoWorld.lumenId)!
        // 15:00 is 62.5% of the day: about 4120 × 1.18 × 0.625 new users.
        #expect((2900...3200).contains(lumen.newUsers!))
        #expect(lumen.hourlyNewUsers.count == 16)
        #expect(lumen.hourlyNewUsers.reduce(0, +) == lumen.newUsers)
        #expect(lumen.revenueSource == .posthog)
        #expect(lumen.reviewsToAnswer == 5)
        let ferry = world.snapshot(for: DemoWorld.ferryId)!
        #expect(ferry.revenue == 3.28)
        #expect(ferry.sales == nil)
        #expect(world.snapshot(for: DemoWorld.atlasId)!.extra?.label == "次付费墙浏览")
    }

    @Test func advancingAddsUsersAndNeverGoesBackInTime() {
        var random = SplitMix64(seed: 2)
        var world = DemoWorld.make(now: afternoon, calendar: calendar, random: &random)
        let before = world.snapshot(for: DemoWorld.lumenId)!
        world.advance(to: afternoon, calendar: calendar, random: &random)
        let after = world.snapshot(for: DemoWorld.lumenId)!
        #expect(after.newUsers! > before.newUsers!)
        #expect(after.fetchedAt > before.fetchedAt)
        #expect(SnapshotChange(from: before, to: after).isUp)
    }

    @Test func scenariosShapeTheNextRefresh() {
        var random = SplitMix64(seed: 3)
        var world = DemoWorld.make(now: afternoon, calendar: calendar, random: &random)

        world.scenario = .quiet
        let quietBefore = world.snapshot(for: DemoWorld.lumenId)!
        world.advance(to: afternoon, calendar: calendar, random: &random)
        #expect(SnapshotChange(from: quietBefore, to: world.snapshot(for: DemoWorld.lumenId)!) == .none)

        world.scenario = .sale
        let saleBefore = world.snapshot(for: DemoWorld.lumenId)!
        world.advance(to: afternoon, calendar: calendar, random: &random)
        let saleAfter = world.snapshot(for: DemoWorld.lumenId)!
        #expect(saleAfter.sales == saleBefore.sales! + 1)
        #expect(SnapshotChange(from: saleBefore, to: saleAfter).hasSale)

        world.scenario = .failure
        #expect(world.snapshot(for: DemoWorld.ferryId)!.failures.map(\.platform) == [.revenueCat])
        #expect(world.snapshot(for: DemoWorld.lumenId)!.failures.isEmpty)
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
        #expect(world.snapshot(for: review.projectId)!.reviewsToAnswer == world.reviews.filter { $0.projectId == review.projectId && $0.needsReply }.count)
    }

    @Test func historyIsStableAndEndsWithToday() {
        var random = SplitMix64(seed: 6)
        let world = DemoWorld.make(now: afternoon, calendar: calendar, random: &random)
        let first = world.history(for: DemoWorld.lumenId, days: 30, calendar: calendar)
        let second = world.history(for: DemoWorld.lumenId, days: 30, calendar: calendar)
        #expect(first == second)
        #expect(first.count == 30)
        #expect(first.last?.newUsers == world.snapshot(for: DemoWorld.lumenId)!.newUsers)
        #expect(world.history(for: DemoWorld.atlasId, days: 7, calendar: calendar).allSatisfy { $0.revenue == nil })
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
        let result = await provider.refresh(lumen)
        #expect(result.reviews?.isEmpty == false)
        let review = try #require(result.reviews?.first { $0.needsReply })
        try await provider.reply(to: review, text: "Thank you", in: lumen)
        #expect(saved.world?.reviews.first { $0.id == review.id }?.reply?.text == "Thank you")
    }
}

final class Saved: @unchecked Sendable {
    var world: DemoWorld?
}
