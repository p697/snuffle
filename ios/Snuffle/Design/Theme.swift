import SnuffleKit
import SwiftUI

/// The "refresh machine" palette: paper, ink and one highlighter colour. Light and dark values live side by side.
enum Palette {
    static let paper = Color(light: 0xF4F4F1, dark: 0x0E0E0C)
    static let card = Color(light: 0xFFFFFF, dark: 0x1A1A17)
    static let ink = Color(light: 0x121210, dark: 0xF4F4F1)
    static let ink2 = Color(light: 0x55554F, dark: 0xB9B9B0)
    static let line = Color(light: 0xE4E4DE, dark: 0x2E2E29)
    static let pill = Color(light: 0xF4F4F1, dark: 0x262622)
    static let faint = Color(light: 0xC9C9C1, dark: 0x4A4A44)
    /// The dark totals strip flips to light in dark mode.
    static let strip = Color(light: 0x121210, dark: 0xF4F4F1)
    static let stripText = Color(light: 0xFFFFFF, dark: 0x121210)
    static let stripMuted = Color(light: 0xB9B9B0, dark: 0x55554F)
    static let up = Color(light: 0x0B7A43, dark: 0x6FD69B)
    static let upSoft = Color(light: 0xE3F3EA, dark: 0x16301F)
    static let bad = Color(light: 0x8C2413, dark: 0xFFC2B5)
    static let badSoft = Color(light: 0xFBE3DD, dark: 0x3A1A14)
    static let badLine = Color(light: 0xE3A99E, dark: 0x7A3A2E)
    static let cat = Color(light: 0x121210, dark: 0x5A5A52)
    static let onAccent = Color(hex: 0x121210)
    static let shadow = Color(light: 0x121210, dark: 0x000000)
}

/// The welcome screen's and the paywall's poster: accent paper with ink type; in dark mode a dark sheet with
/// accent type, so the status bar stays legible.
struct PosterColors {
    var fill: Color
    var ink: Color

    init(accent: Color, scheme: ColorScheme) {
        fill = scheme == .dark ? Palette.card : accent
        ink = scheme == .dark ? accent : Palette.onAccent
    }
}

extension AppSettings.Accent {
    var color: Color {
        switch self {
        case .lemon: Color(hex: 0xFFDD33)
        case .mint: Color(hex: 0x7CF0A8)
        case .peach: Color(hex: 0xFF9E7A)
        case .lilac: Color(hex: 0xB8A6FF)
        }
    }

    var label: String {
        switch self {
        case .lemon: "柠檬黄"
        case .mint: "薄荷绿"
        case .peach: "蜜桃橙"
        case .lilac: "丁香紫"
        }
    }
}

extension ProjectTint {
    var color: Color {
        switch self {
        case .ink: Color(light: 0x121210, dark: 0xF4F4F1)
        case .coral: Color(hex: 0xE4572E)
        case .cocoa: Color(hex: 0x7A5644)
        case .ocean: Color(hex: 0x2F6FDB)
        case .moss: Color(hex: 0x3F7D4E)
        case .plum: Color(hex: 0x7B4BA8)
        }
    }

    var textColor: Color {
        self == .ink ? Color(light: 0xFFFFFF, dark: 0x121210) : .white
    }
}

/// The accent the person picked, available to every view.
extension EnvironmentValues {
    @Entry var accent: Color = Color(hex: 0xFFDD33)
}

enum Typeface {
    /// Big condensed numbers. SF Pro's compressed width carries the same tall, tight figures as the mockups.
    static func number(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy).width(.compressed)
    }

    static func title(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Nonisolated: UIKit resolves the colour on SwiftUI's render thread during animations, and a main-actor
    /// closure there traps on the isolation check.
    nonisolated init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { @Sendable traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// Number and money formatting shared by every screen.
enum Format {
    static func number(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    /// "$943", or "$3.28" when there are cents.
    static func money(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if abs(rounded - rounded.rounded()) < 0.005 {
            return "$" + number(Int(rounded.rounded()))
        }
        return "$" + rounded.formatted(.number.precision(.fractionLength(2)).grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    /// "+48" or "+$300".
    static func delta(users: Int) -> String { "+" + number(users) }
    static func delta(money value: Double) -> String { "+" + money(value) }

    /// "刚刚", "3 分钟前", "2 小时前", "昨天".
    static func ago(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) 小时前" }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        return "\(Int(seconds / 86_400)) 天前"
    }

    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    /// A country or territory name in Chinese from an ISO alpha-2 or alpha-3 code.
    static func place(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let alpha2 = code.count == 3 ? (Territory.alpha2(fromAlpha3: code) ?? code) : code.uppercased()
        return Locale(identifier: "zh-Hans").localizedString(forRegionCode: alpha2) ?? code
    }

    /// A language name in Chinese from a code like "uk_UA".
    static func language(_ code: String?) -> String? {
        guard let code else { return nil }
        let base = String(code.split(whereSeparator: { $0 == "_" || $0 == "-" }).first ?? "")
        return Locale(identifier: "zh-Hans").localizedString(forLanguageCode: base)
    }
}
