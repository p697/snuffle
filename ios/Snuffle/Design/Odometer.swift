import SnuffleKit
import SwiftUI

/// A number whose digits sit on rolling columns, like a car's odometer. The number never leaves the screen: when it
/// changes, only the columns whose digit changed roll forward to the new one, the rightmost a little faster, so a rise
/// reads as the count going up rather than a new number appearing.
struct Odometer: View {
    var text: String
    var size: CGFloat
    var color: Color = Palette.ink

    var body: some View {
        let characters = Array(text)
        let digitCount = characters.filter(\.isNumber).count
        HStack(spacing: 0) {
            ForEach(Array(characters.enumerated()), id: \.offset) { index, character in
                if let digit = character.wholeNumberValue {
                    let column = characters[..<index].filter(\.isNumber).count
                    DigitColumn(digit: digit, fromRight: digitCount - 1 - column, size: size)
                } else {
                    // Separators keep their width; otherwise a busy layout squeezes the comma out. They share the
                    // digits' row height, so "2,882" sits exactly where "9" does.
                    Text(String(character)).fixedSize().frame(height: size)
                }
            }
        }
        .fixedSize()
        // Numbers read left to right in every language; one view per character would otherwise reverse in Arabic.
        .environment(\.layoutDirection, .leftToRight)
        // Each digit column hides 20 stacked rows; without these, baseline alignment would use the last hidden row.
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - size * 0.14 }
        .alignmentGuide(.lastTextBaseline) { $0[.bottom] - size * 0.14 }
        .font(Typeface.number(size))
        .foregroundStyle(color)
        // The hidden rows are clipped from sight but would still catch taps far above and below the number: over the
        // header's buttons, or over the card above. Only the number's own frame takes part in hit testing.
        .allowsHitTesting(false)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

private struct DigitColumn: View {
    var digit: Int
    /// Position from the right: higher columns roll a little slower, as on a real counter.
    var fromRight: Int
    var size: CGFloat

    /// Rows from the top of the strip; the strip holds 0–9 twice, so a roll past 9 keeps going up.
    @State private var position: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<20, id: \.self) { row in
                Text(String(row % 10)).frame(height: size)
            }
        }
        .offset(y: -position * size)
        .frame(height: size, alignment: .top)
        .clipped()
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: size)
        .onAppear { position = Double(digit) }
        .onChange(of: digit) { old, new in roll(from: old, to: new) }
    }

    /// Rolls forward to a new digit, wrapping past 9 when the new digit is smaller, then settles on the same digit in
    /// the first half of the strip without moving.
    private func roll(from old: Int, to new: Int) {
        guard !reduceMotion else {
            position = Double(new)
            return
        }
        let target = Double(new < old ? new + 10 : new)
        withAnimation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.6 + Double(fromRight) * 0.09)) {
            position = target
        } completion: {
            if position >= 10 { position -= 10 }
        }
    }
}

#Preview {
    @Previewable @State var value = 1053
    VStack(spacing: 20) {
        Odometer(text: Format.number(value), size: 56)
        Button(String("+8")) { value += 8 }
    }
}
