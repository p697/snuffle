import SwiftUI
import XCTest
@testable import Snuffle

/// The labels under a stacked chart's axis, from a week of bars to a year of them.
@MainActor
final class StackedChartAxisTests: XCTestCase {
    func testAWeekLabelsEveryDay() {
        let labels = (20...26).map { "11/\($0)" }
        let placed = StackedChart.axisLabels(labels, plotWidth: 300, labelWidth: 29)
        XCTAssertEqual(Set(placed.keys), Set(labels))
        XCTAssertTrue(placed.values.allSatisfy { $0 == .top })
    }

    func testDenseBarsAreLabeledEveryFewBackFromTheLatest() {
        let labels = (0..<87).map { "d\($0)" }
        let placed = StackedChart.axisLabels(labels, plotWidth: 300, labelWidth: 29)
        XCTAssertEqual(Set(placed.keys), ["d86", "d65", "d44", "d23", "d2"])
        XCTAssertEqual(placed["d86"], .topTrailing)
        XCTAssertEqual(placed["d2"], .topLeading)
    }

    func testLabelsNeverTouchAndStayInsideThePlot() {
        for width in [240.0, 300, 338, 700] as [CGFloat] {
            for labelWidth in [20.0, 29, 60] as [CGFloat] {
                for count in 1...400 {
                    let labels = (0..<count).map { "\($0)" }
                    let placed = StackedChart.axisLabels(labels, plotWidth: width, labelWidth: labelWidth)
                    let slot = width / CGFloat(count)
                    let spans = (0..<count).compactMap { index -> ClosedRange<CGFloat>? in
                        guard let anchor = placed["\(index)"] else { return nil }
                        let center = (CGFloat(index) + 0.5) * slot
                        let start = anchor == .topLeading ? center : anchor == .topTrailing ? center - labelWidth : center - labelWidth / 2
                        return start...(start + labelWidth)
                    }
                    let context = "count \(count), width \(width), label \(labelWidth)"
                    XCTAssertNotNil(placed["\(count - 1)"], context)
                    XCTAssertGreaterThanOrEqual(spans.first!.lowerBound, 0, context)
                    XCTAssertLessThanOrEqual(spans.last!.upperBound, width, context)
                    for (left, right) in zip(spans, spans.dropFirst()) {
                        XCTAssertGreaterThanOrEqual(right.lowerBound - left.upperBound, 8, context)
                    }
                }
            }
        }
    }

    func testNothingToLabel() {
        XCTAssertTrue(StackedChart.axisLabels([], plotWidth: 300, labelWidth: 29).isEmpty)
        XCTAssertTrue(StackedChart.axisLabels(["11/26"], plotWidth: 0, labelWidth: 29).isEmpty)
    }
}
