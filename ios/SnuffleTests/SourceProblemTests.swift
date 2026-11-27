import SnuffleKit
import XCTest
@testable import Snuffle

/// What the note after a refresh, the status line and the dot on 项目 say about failed sources.
@MainActor
final class SourceProblemTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_000_000)
    private let lumen = DemoWorld.projects.first { $0.id == DemoWorld.lumenId }!
    private let ferry = DemoWorld.projects.first { $0.id == DemoWorld.ferryId }!

    private func snapshot(_ project: Project, _ failures: [(Platform, FailureKind)], readAt: [Platform: Date] = [:]) -> ProjectSnapshot {
        ProjectSnapshot(projectId: project.id, fetchedAt: day, dayStart: day,
                        failures: failures.map { SourceFailure(platform: $0.0, message: "x", kind: $0.1) }, readAt: readAt)
    }

    private func problem(_ snapshots: [ProjectSnapshot], muted: Set<Platform> = []) -> SourceProblem? {
        let byId = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.projectId, $0) })
        return SourceProblem(projects: [lumen, ferry], snapshot: { byId[$0] }, muted: muted)
    }

    func testNothingFailedSaysNothing() {
        XCTAssertNil(problem([snapshot(lumen, []), snapshot(ferry, [])]))
    }

    func testFailuresOfEveryProjectAreOneNote() throws {
        let earlier = day.addingTimeInterval(-600)
        let found = try XCTUnwrap(problem([
            snapshot(lumen, [(.googlePlay, .serverError)], readAt: [.googlePlay: day]),
            snapshot(ferry, [(.revenueCat, .rateLimited)], readAt: [.revenueCat: earlier]),
        ]))
        XCTAssertEqual(found.kind, .failed)
        XCTAssertEqual(found.platforms, [.revenueCat, .googlePlay])
        XCTAssertEqual(found.projects, [lumen.id, ferry.id])
        XCTAssertEqual(found.stoppedAt, earlier, "the oldest number held back")
    }

    func testASignInIsNamedBeforePassingFailures() throws {
        let found = try XCTUnwrap(problem([
            snapshot(lumen, [(.googlePlay, .unauthorized)]),
            snapshot(ferry, [(.revenueCat, .network)]),
        ]))
        XCTAssertEqual(found.kind, .signIn)
        XCTAssertEqual(found.platforms, [.googlePlay])
        XCTAssertEqual(found.projects, [lumen.id])
    }

    func testMutedSourcesAreNotNamed() throws {
        XCTAssertNil(problem([snapshot(lumen, [(.googlePlay, .unauthorized)]), snapshot(ferry, [])], muted: [.googlePlay]))
        let found = try XCTUnwrap(problem([snapshot(lumen, [(.googlePlay, .unauthorized), (.posthog, .serverError)]), snapshot(ferry, [])], muted: [.googlePlay]))
        XCTAssertEqual(found.kind, .failed)
        XCTAssertEqual(found.platforms, [.posthog])
    }

    func testNoConnectionAnywhereIsOneSentence() throws {
        let last = day.addingTimeInterval(-300)
        let all = { (project: Project) in project.platforms.map { ($0, FailureKind.network) } }
        let found = try XCTUnwrap(problem([
            snapshot(lumen, all(lumen), readAt: [.posthog: last, .appStore: day.addingTimeInterval(-900)]),
            snapshot(ferry, all(ferry)),
        ], muted: [.googlePlay]))
        XCTAssertEqual(found.kind, .offline)
        XCTAssertEqual(found.platforms, [])
        XCTAssertEqual(found.stoppedAt, last, "the latest read of any")

        // One source still answering means the connection is there: the failing ones are named.
        let partly = try XCTUnwrap(problem([snapshot(lumen, [(.posthog, .network)]), snapshot(ferry, all(ferry))]))
        XCTAssertEqual(partly.kind, .failed)
    }
}
