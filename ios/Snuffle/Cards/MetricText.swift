import SnuffleKit
import SwiftUI

/// How a metric reads on screen: its value, its "+N" and the line that explains it.
extension Metric {
    /// "+48" or "+$300".
    func delta(_ rise: Double) -> String {
        isMoney ? Format.delta(money: rise) : Format.delta(users: Int(rise.rounded()))
    }

    /// The value as shown in the totals strip and on a card; "–" when unknown.
    func text(_ value: Double?) -> String {
        value.map(format) ?? "–"
    }

    /// What the number counts, in the library and under a big number, for this project's counting.
    func explanation(in project: Project) -> String {
        switch self {
        case .newUsers:
            switch project.metrics.newUsers {
            case .event(let name) where name == MetricSettings.signupEvent: String(localized: "今天 · 按注册事件算")
            case .event(let name): String(localized: "今天 · 按 \(name) 的人数算")
            case .firstSeen: String(localized: "今天 · 按开始使用的人算")
            }
        case .activeToday: String(localized: "今天有过任何动作的人")
        case .activeWeek: String(localized: "最近 7 天有过动作的人 · 每小时更新")
        case .activeMonth: String(localized: "最近 30 天有过动作的人 · 每小时更新")
        case .totalUsers: String(localized: "PostHog 里登录过的人 · 每小时更新")
        case .online: String(localized: "最近 1 分钟")
        case .pageviews: String(localized: "今天的页面浏览次数")
        case .event(let name, let people):
            people ? String(localized: "今天发过 \(name) 的人数") : String(localized: "今天 \(name) 发生的次数")
        case .revenue:
            switch project.metrics.revenue {
            case .posthogEvent(let event, _): String(localized: "今天 · PostHog 事件 \(event) 的金额合计")
            case .revenueCat: String(localized: "今天 · RevenueCat 当日总额（UTC）")
            case .none: String(localized: "还没选怎么算收入")
            }
        case .orders: String(localized: "今天的付费笔数")
        case .mrr: String(localized: "RevenueCat 月经常性收入 · 每小时更新")
        case .activeSubscriptions: String(localized: "RevenueCat 在订人数 · 每小时更新")
        case .activeTrials: String(localized: "RevenueCat 试用中的人 · 每小时更新")
        case .revenueLast28Days: String(localized: "RevenueCat 近 28 天收入 · 每小时更新")
        case .reviewsToAnswer: String(localized: "App Store 全部 + Google Play 近 7 天")
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
