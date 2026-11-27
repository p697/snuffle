import SnuffleKit
import XCTest
@testable import Snuffle

/// Which candidate the connect flow links without asking.
@MainActor
final class ConnectMatchTests: XCTestCase {
    private func session(name: String) -> ConnectSession {
        ConnectSession(project: Project(name: name, tint: .ink), isNewProject: name.isEmpty)
    }

    private func pick(_ names: [String], for project: String) -> String? {
        session(name: project).obvious(names) { [$0] }
    }

    func testTheOnlyCandidateIsLinkedWhenNothingIsKnownYet() {
        XCTAssertEqual(pick(["Clawket"], for: ""), "Clawket")
    }

    /// A RevenueCat key reads one project: another product's key must not link that product silently.
    func testALoneCandidateWithAnotherNameIsAskedAbout() {
        XCTAssertNil(pick(["Clawket"], for: "Isaac Codex"))
    }

    func testNamesMatchIgnoringCaseSpacesAndPunctuation() {
        XCTAssertEqual(pick(["Clawket", "com.example.isaaccodex"], for: "Isaac Codex"), "com.example.isaaccodex")
        XCTAssertEqual(pick(["Clawket"], for: "clawket"), "Clawket")
    }

    func testSeveralMatchesAreAskedAbout() {
        XCTAssertNil(pick(["Isaac Codex", "Isaac Codex Lite"], for: "Isaac"))
    }
}
