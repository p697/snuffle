import Foundation
import Testing
@testable import SnuffleKit

@Suite("Formatting")
struct FormatTests {
    @Test func numbersUseTheLanguagesSeparatorsWithLatinDigits() {
        #expect(Format.number(12_345, locale: Locale(identifier: "en_US")) == "12,345")
        #expect(Format.number(12_345, locale: Locale(identifier: "de_DE")) == "12.345")
        // Arabic and Hindi default to their own digits; the odometer only draws 0–9.
        #expect(Format.number(12_345, locale: Locale(identifier: "ar_SA")).allSatisfy { !$0.isNumber || $0.isASCII })
        #expect(Format.number(7, locale: Locale(identifier: "hi_IN")) == "7")
    }

    @Test func moneyIsDollarsWithCentsOnlyWhenThereAreSome() {
        #expect(Format.money(943, locale: Locale(identifier: "en_US")) == "$943")
        #expect(Format.money(3.28, locale: Locale(identifier: "en_US")) == "$3.28")
        #expect(Format.money(943, locale: Locale(identifier: "zh_CN")) == "$943")
        #expect(Format.money(3.28, locale: Locale(identifier: "de_DE")).hasPrefix("3,28"))
        // Right-to-left text keeps an amount in reading order inside an isolate.
        let arabic = Format.money(2488, locale: Locale(identifier: "ar_SA"))
        #expect(arabic.hasPrefix("\u{2066}") && arabic.hasSuffix("\u{2069}"))
    }

    @Test func aMomentNamesTheDayOnlyWhenItIsNotToday() {
        let now = Date()
        let earlier = now.addingTimeInterval(-60)
        if Calendar.current.isDate(earlier, inSameDayAs: now) { #expect(Format.moment(earlier, now: now) == Format.clock(earlier)) }
        let yesterday = now.addingTimeInterval(-86_400)
        #expect(Format.moment(yesterday, now: now).count > Format.clock(yesterday).count)
    }

    @Test func ratesKeepTwoDecimalsLikePlayConsole() {
        #expect(Format.rate(0.0109, locale: Locale(identifier: "en_US")) == "1.09%")
        #expect(Format.rate(0.003, locale: Locale(identifier: "en_US")) == "0.30%")
        #expect(Format.rate(0.0109, locale: Locale(identifier: "de_DE")).hasPrefix("1,09"))
        #expect(Metric.crashRate.format(0.0027).contains("27"))
    }
}
