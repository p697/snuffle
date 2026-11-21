import SnuffleKit
import SwiftUI

/// How new users, revenue and the card's second number are counted. Shared by the connect flow and the editor.
struct MetricsCard: View {
    @Binding var project: Project

    private enum NewUsers: Hashable { case signup, firstSeen, custom }
    private enum Revenue: Hashable { case posthog, revenueCat, none }
    private enum Extra: Hashable { case installs, custom, none }

    var body: some View {
        CardGroup {
            block(title: "新增用户") {
                ChoiceBar(options: [(.signup, "注册事件"), (.firstSeen, "开始使用"), (.custom, "自定义事件")], selection: newUsers)
                if case .event(let name) = project.metrics.newUsers {
                    EventField(label: "事件名", text: Binding(get: { name }, set: { project.metrics.newUsers = .event($0) }))
                }
                Note(text: "注册事件和自定义事件按今天触发的人数算；开始使用是今天第一次打开 App 或在网站登录、之前 30 天没出现过的人，不含没登录的网站访客。项目里只有网站访客时，才按访客算。")
            }
            RowDivider()
            block(title: "收入") {
                ChoiceBar(options: revenueOptions, selection: revenue)
                if case .posthogEvent(let event, let property) = project.metrics.revenue {
                    HStack(spacing: 8) {
                        EventField(label: "事件", text: Binding(get: { event }, set: { project.metrics.revenue = .posthogEvent(event: $0, valueProperty: property) }))
                        EventField(label: "金额", text: Binding(get: { property }, set: { project.metrics.revenue = .posthogEvent(event: event, valueProperty: $0) }))
                    }
                }
                Note(text: "PostHog 付费事件把金额加起来，并能列出每一笔订单；RevenueCat 只给每天的总额。金额按美元显示。")
            }
            RowDivider()
            block(title: "卡片上的第二个数") {
                ChoiceBar(options: [(.installs, "今天的安装"), (.custom, "自定义事件"), (.none, "不显示")], selection: extra)
                if case .event(let name, let label) = project.metrics.extra {
                    HStack(spacing: 8) {
                        EventField(label: "事件", text: Binding(get: { name }, set: { project.metrics.extra = .event(name: $0, label: label) }))
                        EventField(label: "显示为", text: Binding(get: { label }, set: { project.metrics.extra = .event(name: name, label: $0) }), monospaced: false)
                    }
                }
            }
        }
    }

    private func block(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
            content()
        }
        .padding(.vertical, 12)
    }

    private var revenueOptions: [(value: Revenue, label: String)] {
        var options: [(value: Revenue, label: String)] = [(.posthog, "PostHog 事件")]
        if project.revenueCat != nil { options.append((.revenueCat, "RevenueCat")) }
        options.append((.none, "不统计"))
        return options
    }

    private var newUsers: Binding<NewUsers> {
        Binding {
            switch project.metrics.newUsers {
            case .firstSeen: .firstSeen
            case .event(let name): name == MetricSettings.signupEvent ? .signup : .custom
            }
        } set: { choice in
            switch choice {
            case .signup: project.metrics.newUsers = .event(MetricSettings.signupEvent)
            case .firstSeen: project.metrics.newUsers = .firstSeen
            case .custom: project.metrics.newUsers = .event("")
            }
        }
    }

    private var revenue: Binding<Revenue> {
        Binding {
            switch project.metrics.revenue {
            case .posthogEvent: .posthog
            case .revenueCat: .revenueCat
            case .none: .none
            }
        } set: { choice in
            switch choice {
            case .posthog: project.metrics.revenue = .posthogEvent(event: "purchase", valueProperty: "value")
            case .revenueCat: project.metrics.revenue = .revenueCat
            case .none: project.metrics.revenue = .none
            }
        }
    }

    private var extra: Binding<Extra> {
        Binding {
            switch project.metrics.extra {
            case .installs: .installs
            case .event: .custom
            case .none: .none
            }
        } set: { choice in
            switch choice {
            case .installs: project.metrics.extra = .installs
            case .custom: project.metrics.extra = .event(name: "", label: "次")
            case .none: project.metrics.extra = .none
            }
        }
    }
}

/// A grey field with a small label, for an event or property name.
private struct EventField: View {
    var label: String
    @Binding var text: String
    var monospaced = true

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 13)).foregroundStyle(Palette.ink2)
            TextField(label, text: $text)
                .font(monospaced ? .system(size: 13).monospaced() : .system(size: 14))
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Palette.pill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct Note: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }
}
