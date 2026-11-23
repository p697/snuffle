import SnuffleKit
import XCTest
@testable import Snuffle

/// The metric library's numbers while a person flips counting and scope back and forth.
@MainActor
final class MeasuredNumbersTests: XCTestCase {
    func testNumbersFromAnotherScopeAreNeverShown() {
        let apps = MetricSettings(newUsers: .firstSeen, revenue: .revenueCat, excludedSurfaces: [.visitors])
        let iosOnly = apps.leaving(out: [.visitors, .android])
        var measured = MeasuredNumbers()
        measured.add([.activeMonth: 814, .mrr: 86], countedAs: apps)
        XCTAssertEqual(measured.values(countedAs: apps), [.activeMonth: 814, .mrr: 86])

        // Android off: only what does not follow the scope is still shown until it is read again.
        XCTAssertEqual(measured.values(countedAs: iosOnly), [.mrr: 86])
        measured.add([.activeMonth: 174], countedAs: iosOnly)
        XCTAssertEqual(measured.values(countedAs: iosOnly), [.activeMonth: 174, .mrr: 86])

        // Android back on: the iOS-only number is not taken for the first scope's.
        XCTAssertEqual(measured.values(countedAs: apps), [.mrr: 86])
    }
}
