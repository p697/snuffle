import SwiftUI

/// A number whose digits sit on rolling columns.
///
/// - While `spinning`, every column loops through 0–9 (the slot machine).
/// - When spinning stops, columns land one by one from the left: 420 ms each, 110 ms apart, with a small overshoot.
/// - When the value changes without spinning, only the changed columns roll forward to their new digit.
struct Odometer: View {
    var text: String
    var size: CGFloat
    var spinning = false
    var color: Color = Palette.ink

    var body: some View {
        let characters = Array(text)
        let digitCount = characters.filter(\.isNumber).count
        HStack(spacing: 0) {
            ForEach(Array(characters.enumerated()), id: \.offset) { index, character in
                if let digit = character.wholeNumberValue {
                    let column = characters[..<index].filter(\.isNumber).count
                    DigitColumn(digit: digit, spinning: spinning, column: column, fromRight: digitCount - 1 - column, size: size)
                } else {
                    // Separators keep their width; otherwise a busy layout squeezes the comma out. They share the
                    // digits' row height, so "2,882" sits exactly where "9" does.
                    Text(String(character)).fixedSize().frame(height: size)
                }
            }
        }
        .fixedSize()
        // Each digit column hides 22 stacked rows; without these, baseline alignment would use the last hidden row.
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - size * 0.14 }
        .alignmentGuide(.lastTextBaseline) { $0[.bottom] - size * 0.14 }
        .font(Typeface.number(size))
        .foregroundStyle(color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spinning ? "正在刷新" : text)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

private struct DigitColumn: View {
    var digit: Int
    var spinning: Bool
    /// Position from the left; landing order.
    var column: Int
    /// Position from the right; higher columns spin and roll a little slower.
    var fromRight: Int
    var size: CGFloat

    @State private var motion = Motion.rest(0)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Digit units are line heights; the strip holds 0–9 twice plus two spare rows.
    enum Motion: Equatable {
        case rest(Double)
        case spin(start: Date, period: Double, phase: Double)
        case move(start: Date, from: Double, to: Double, duration: Double, overshoot: Bool)

        func offset(at date: Date) -> Double {
            switch self {
            case .rest(let value):
                return value
            case .spin(let start, let period, let phase):
                let turns = date.timeIntervalSince(start) / period
                return (phase + turns * 10).truncatingRemainder(dividingBy: 10)
            case .move(let start, let from, let to, let duration, let overshoot):
                let t = min(1, max(0, date.timeIntervalSince(start) / duration))
                let eased = overshoot ? Self.easeOutBack(t) : Self.easeOutQuint(t)
                return from + (to - from) * eased
            }
        }

        var isAnimating: Bool {
            if case .rest = self { false } else { true }
        }

        static func easeOutBack(_ t: Double) -> Double {
            let c1 = 1.70158, c3 = c1 + 1
            return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
        }

        static func easeOutQuint(_ t: Double) -> Double { 1 - pow(1 - t, 5) }
    }

    var body: some View {
        TimelineView(.animation(paused: !motion.isAnimating)) { context in
            let offset = motion.offset(at: context.date)
            let height = size
            VStack(spacing: 0) {
                ForEach(0..<22, id: \.self) { row in
                    Text(String(row % 10))
                        .frame(height: height)
                }
            }
            .offset(y: -offset.truncatingRemainder(dividingBy: 10) * height)
            .frame(height: height, alignment: .top)
            .clipped()
            .blur(radius: isSpinning ? 1.4 : 0)
            .onChange(of: context.date) { _, now in settleIfDone(now) }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: size)
        .onAppear { motion = .rest(Double(digit)) }
        .onChange(of: spinning) { _, spinning in
            spinning ? startSpin() : land()
        }
        .onChange(of: digit) { old, new in
            // The digit usually changes in the same update that stops the spin; landing owns that change,
            // whichever of the two callbacks runs first.
            switch motion {
            case .spin, .move(_, _, _, _, true): return
            default: if !spinning { roll(from: old, to: new) }
            }
        }
    }

    private var isSpinning: Bool {
        if case .spin = motion { !reduceMotion } else { false }
    }

    private func startSpin() {
        guard !reduceMotion else { return }
        motion = .spin(start: .now, period: 0.4 + Double(fromRight) * 0.06, phase: Double(digit))
    }

    /// Stops the spin: jump three rows short of the target, then ease in with a little overshoot.
    private func land() {
        guard !reduceMotion else {
            motion = .rest(Double(digit))
            return
        }
        let target = Double(digit + 10)
        motion = .move(start: .now.addingTimeInterval(Double(column) * 0.11), from: target - 3, to: target, duration: 0.42, overshoot: true)
    }

    /// Rolls forward to a new digit, wrapping past 9 when the new digit is smaller.
    private func roll(from old: Int, to new: Int) {
        guard !reduceMotion, old != new else {
            motion = .rest(Double(new))
            return
        }
        let target = Double(new < old ? new + 10 : new)
        motion = .move(start: .now, from: Double(old), to: target, duration: 0.6 + Double(fromRight) * 0.09, overshoot: false)
    }

    private func settleIfDone(_ now: Date) {
        if case .move(let start, _, let to, let duration, _) = motion, now.timeIntervalSince(start) >= duration {
            motion = .rest(to.truncatingRemainder(dividingBy: 10))
        }
    }
}

#Preview {
    @Previewable @State var spinning = false
    @Previewable @State var value = 3406
    VStack(spacing: 20) {
        Odometer(text: Format.number(value), size: 56, spinning: spinning)
        Button(spinning ? "落定" : "转起来") {
            if spinning { value += Int.random(in: 1...60) }
            spinning.toggle()
        }
    }
}
