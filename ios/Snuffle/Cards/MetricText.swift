import SnuffleKit
import SwiftUI

/// How a metric reads on screen: its value, its "+N", what it is set against and the line that explains it.
extension Metric {
    /// "+48" or "+$300".
    func delta(_ rise: Double) -> String {
        isMoney ? Format.delta(money: rise) : Format.delta(users: Int(rise.rounded()))
    }

    /// The value as shown on a card or a board; "–" when unknown.
    func text(_ value: Double?) -> String {
        value.map(format) ?? "–"
    }

    /// The name as the project counts it: a project counting installations has installs, not users.
    func title(in project: Project) -> String {
        guard project.metrics.unit == .install else { return title }
        switch self {
        case .totalUsers: return String(localized: "累计安装")
        case .newUsers where project.metrics.newUsers == .firstSeen: return String(localized: "新增安装")
        default: return title
        }
    }

    /// What a number is set against, ready to show: "今天 +6", "昨天此时 54", "▲ 20.7%" or "阈值 1.09%".
    struct ReferenceText: Equatable {
        enum Tone { case plain, up, down, muted }
        var text: String
        var tone: Tone
    }

    /// `compact` is for a narrow column: today's numbers read as a change on yesterday by now instead of its count.
    func reference(in snapshot: ProjectSnapshot?, compact: Bool = false) -> ReferenceText? {
        guard let reference, let snapshot else { return nil }
        if reference == .threshold {
            guard let threshold, let now = snapshot[self] else { return nil }
            let limit = Format.rate(threshold)
            return now > threshold
                ? ReferenceText(text: String(localized: "超过阈值 \(limit)"), tone: .down)
                : ReferenceText(text: String(localized: "阈值 \(limit)"), tone: .muted)
        }
        guard let before = snapshot.previous[self] else { return nil }
        switch reference {
        case .today:
            guard let now = snapshot[self] else { return nil }
            return ReferenceText(text: String(localized: "今天 \(Format.delta(users: max(0, Int((now - before).rounded()))))"), tone: .plain)
        case .sameTimeYesterday:
            if compact, let now = snapshot[self], let change = Self.change(now, from: before) { return change }
            return ReferenceText(text: String(localized: "昨天此时 \(Format.number(Int(before.rounded())))"), tone: .muted)
        case .previousPeriod:
            guard let now = snapshot[self] else { return nil }
            return Self.change(now, from: before)
        case .threshold:
            return nil
        }
    }

    /// "▲ 20.7%", "▼ 9.4%" or "持平" against the period before; nil when there was nothing to compare with.
    static func change(_ now: Double, from before: Double) -> ReferenceText? {
        guard before > 0 else { return nil }
        let change = (now - before) / before
        if abs(change) < 0.0005 { return ReferenceText(text: String(localized: "持平"), tone: .muted) }
        return change > 0
            ? ReferenceText(text: "▲ " + Format.percent(change), tone: .up)
            : ReferenceText(text: "▼ " + Format.percent(-change), tone: .down)
    }

    /// What the number counts, in a line: shown in the library and under it on the board. The definition card says
    /// the rest.
    func explanation(in project: Project) -> String {
        let settings = project.metrics
        let installs = settings.unit == .install
        switch self {
        case .newUsers:
            switch settings.newUsers {
            case .event(let name) where name == MetricSettings.signupEvent: return String(localized: "今天 · 按注册事件算")
            case .event(let name): return String(localized: "今天 · 按 \(name) 的人数算")
            case .firstSeen: return installs ? String(localized: "今天第一次打开的安装") : String(localized: "今天第一次出现的人")
            }
        case .activeToday: return installs ? String(localized: "今天打开过的安装") : String(localized: "今天用过的人")
        case .activeWeek: return installs ? String(localized: "最近 7 天打开过的安装，含今天") : String(localized: "最近 7 天用过的人，含今天")
        case .activeMonth: return installs ? String(localized: "最近 30 天打开过的安装，含今天 · 每小时更新") : String(localized: "最近 30 天用过的人，含今天 · 每小时更新")
        case .newWeek:
            if case .event(let name) = settings.newUsers {
                return name == MetricSettings.signupEvent ? String(localized: "最近 7 天注册的人，含今天") : String(localized: "最近 7 天发过 \(name) 的人，含今天")
            }
            return installs ? String(localized: "最近 7 天第一次打开的安装，含今天") : String(localized: "最近 7 天第一次出现的人，含今天")
        case .totalUsers:
            if let since = settings.since {
                let day = Format.day(since, in: project.zone)
                return installs ? String(localized: "\(day) 起打开过的所有安装") : String(localized: "\(day) 起出现过的所有人")
            }
            return installs ? String(localized: "打开过的所有安装") : String(localized: "出现过的所有人")
        case .online: return String(localized: "最近 1 分钟")
        case .pageviews: return String(localized: "今天网页浏览和 App 页面切换的次数")
        case .event(let name, let people):
            return people ? String(localized: "今天发过 \(name) 的人数") : String(localized: "今天 \(name) 发生的次数")
        case .revenue:
            switch settings.revenue {
            case .posthogEvent(let event, _): return String(localized: "今天 · PostHog 事件 \(event) 的金额合计")
            case .revenueCat: return String(localized: "今天 · RevenueCat 当日总额（UTC）")
            case .none: return String(localized: "还没选怎么算收入")
            }
        case .revenueWeek, .revenueMonth:
            let week = self == .revenueWeek
            switch settings.revenue {
            case .posthogEvent(let event, _):
                return week ? String(localized: "最近 7 天，含今天 · PostHog 事件 \(event) 的金额合计") : String(localized: "最近 30 天，含今天 · PostHog 事件 \(event) 的金额合计")
            case .revenueCat:
                return week ? String(localized: "最近 7 天，含今天 · RevenueCat 按 UTC 日期") : String(localized: "最近 30 天，含今天 · RevenueCat 按 UTC 日期")
            case .none: return String(localized: "还没选怎么算收入")
            }
        case .orders: return String(localized: "今天的付费笔数")
        case .ordersWeek: return String(localized: "最近 7 天的付费笔数，含今天")
        case .ordersMonth: return String(localized: "最近 30 天的付费笔数，含今天")
        case .mrr: return String(localized: "RevenueCat 月经常性收入 · 每小时更新")
        case .activeSubscriptions: return String(localized: "RevenueCat 在订人数 · 每小时更新")
        case .activeTrials: return String(localized: "RevenueCat 试用中的人 · 每小时更新")
        case .revenueLast28Days: return String(localized: "RevenueCat 近 28 天收入 · 每小时更新")
        case .reviewsToAnswer: return String(localized: "App Store 最近 200 条 + Google Play 连接以来")
        case .rating:
            let places = (project.appStore?.countries ?? []).compactMap(Format.place)
            return places.isEmpty
                ? String(localized: "重新连接 App Store，选好读哪些地区")
                : String(localized: "\(places.formatted(.list(type: .and))) 的平均分，按评分数加权 · 每小时更新")
        case .crashRate: return String(localized: "Google Play · 近 28 天使用时遇到崩溃的人占比")
        case .anrRate: return String(localized: "Google Play · 近 28 天使用时遇到无响应的人占比")
        }
    }
}

extension Metric.ReferenceText.Tone {
    var color: Color {
        switch self {
        case .plain: Palette.ink
        case .up: Palette.up
        case .down: Palette.bad
        case .muted: Palette.ink2
        }
    }
}

extension Project {
    /// The zone the project's days start in.
    var zone: TimeZone { posthog.flatMap { TimeZone(identifier: $0.timeZone) } ?? .current }

    /// "UTC" when the project's days start at another hour than the phone's, so a "today" that ends at 8 in the
    /// morning is never a surprise; nil when they start together.
    var dayZoneLabel: String? {
        let now = Date()
        guard posthog != nil, zone.secondsFromGMT(for: now) != TimeZone.current.secondsFromGMT(for: now) else { return nil }
        if zone.secondsFromGMT(for: now) == 0 { return "UTC" }
        return zone.localizedName(for: .shortGeneric, locale: .current) ?? zone.identifier
    }
}

/// Platform names and colours, the same on every chart: iOS blue, Android orange, the web green, the rest grey.
enum PlatformStyle {
    static func name(_ key: String) -> String {
        switch key.lowercased() {
        case "ios", "ipados": "iOS"
        case "android": "Android"
        case "web": String(localized: "网页")
        case Surface.visitors.rawValue: String(localized: "网站访客")
        case Surface.other.rawValue: String(localized: "其他")
        case "", "null": String(localized: "未知")
        default: key
        }
    }

    static func color(_ key: String) -> Color {
        switch key.lowercased() {
        case "ios", "ipados": Color(light: 0x2F6FDB, dark: 0x4F84E8)
        case "android": Color(light: 0xD2691E, dark: 0xD06E22)
        case "web": Color(light: 0x1E8C6E, dark: 0x22A07B)
        default: Color(light: 0x8A8A80, dark: 0x6E6E66)
        }
    }
}

enum NumberSize {
    /// A big number's size: smaller as it gets longer, so seven digits still fit half a card.
    static func fit(_ text: String, base: CGFloat) -> CGFloat {
        let length = text.count
        if length <= 5 { return base }
        if length <= 7 { return (base * 0.84).rounded() }
        if length <= 9 { return (base * 0.7).rounded() }
        return (base * 0.58).rounded()
    }
}
