import Foundation

/// Numbers, money, times and place names for the app and its widgets, in the person's language and with their
/// separators. Digits stay Latin: the odometer rolls and the condensed number face draws 0–9.
public enum Format {
    /// The person's locale with Latin digits.
    static func latin(_ base: Locale = .current) -> Locale {
        var components = Locale.Components(locale: base)
        components.numberingSystem = Locale.NumberingSystem("latn")
        return Locale(components: components)
    }

    public static func number(_ value: Int) -> String { number(value, locale: .current) }

    static func number(_ value: Int, locale: Locale) -> String {
        value.formatted(.number.locale(latin(locale)))
    }

    /// Amounts are US dollars: "$943", "$3.28" in English, "943 $" in German. Cents only when there are some.
    public static func money(_ value: Double) -> String { money(value, locale: .current) }

    static func money(_ value: Double, locale: Locale) -> String {
        let rounded = (value * 100).rounded() / 100
        let whole = abs(rounded - rounded.rounded()) < 0.005
        return leftToRight(rounded.formatted(
            .currency(code: "USD").presentation(.narrow).precision(.fractionLength(whole ? 0 : 2)).locale(latin(locale))
        ), locale: locale)
    }

    /// "20.7%" in the person's language, one decimal at most: a change from the period before.
    public static func percent(_ fraction: Double) -> String { percent(fraction, locale: .current) }

    static func percent(_ fraction: Double, locale: Locale) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0...1)).locale(latin(locale)))
    }

    /// "11/26" or "26.11.", a day without the year, as the person writes it.
    public static func day(_ date: Date, in zone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .omitted).month(.defaultDigits).day().locale(latin())
        style.timeZone = zone
        return date.formatted(style)
    }

    /// A number as HogQL writes it: "1", "0.5". Never localized.
    public static func plain(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    /// "+48" or "+$300".
    public static func delta(users: Int) -> String { "+" + number(users) }
    public static func delta(money value: Double) -> String { leftToRight("+" + money(value), locale: .current) }

    /// In Arabic text an amount like "2,488 US$" would be reordered into "US$ 2,488"-like noise; an isolate keeps it
    /// in reading order. Left-to-right languages get the plain string.
    static func leftToRight(_ text: String, locale: Locale) -> String {
        guard locale.language.characterDirection == .rightToLeft else { return text }
        return "\u{2066}" + text.replacingOccurrences(of: "\u{2066}", with: "").replacingOccurrences(of: "\u{2069}", with: "") + "\u{2069}"
    }

    /// "刚刚", then "3 分钟前", "2 小时前", "昨天"… in the person's language.
    public static func ago(_ date: Date, now: Date = .now) -> String {
        if now.timeIntervalSince(date) < 60 { return String(localized: "刚刚", bundle: .module) }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = latin()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    /// "20:05" or "8:05 PM", as the person's clock shows it.
    public static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(latin()))
    }

    /// A country or territory name from an ISO alpha-2 or alpha-3 code.
    public static func place(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let alpha2 = code.count == 3 ? (Territory.alpha2(fromAlpha3: code) ?? code) : code.uppercased()
        return Locale.current.localizedString(forRegionCode: alpha2) ?? code
    }

    /// A language name from a code like "uk_UA".
    public static func language(_ code: String?) -> String? {
        guard let code else { return nil }
        let base = String(code.split(whereSeparator: { $0 == "_" || $0 == "-" }).first ?? "")
        return Locale.current.localizedString(forLanguageCode: base)
    }
}
