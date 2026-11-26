import SnuffleKit
import SwiftUI

/// The two numbers whose counting a project chooses.
enum CountingKind: Hashable {
    case newUsers, revenue
}

/// "新增用户怎么算" or "收入怎么算", pushed from the metric library.
struct CountingPage: View {
    var kind: CountingKind
    @Binding var project: Project

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BackButton()
                PageTitle(
                    title: kind == .newUsers ? String(localized: "新增用户怎么算") : String(localized: "收入怎么算"),
                    subtitle: String(localized: "这个项目里显示这个数的地方都按这里算。右边是按这种算法今天的数。")
                )
                CountingChoices(kind: kind, project: $project)
            }
            .padding(16)
        }
        .sheetPage()
    }
}

/// The ways to count one number, each with what it counts today, so the right one is the one that matches.
struct CountingChoices: View {
    var kind: CountingKind
    @Binding var project: Project
    @Environment(AppModel.self) private var model
    @State private var values: [Option: Double] = [:]
    @State private var loading = false
    @State private var choosingEvent = false

    enum Option: Hashable {
        case signup, firstSeen, event(String)
        case posthogRevenue, revenueCat, noRevenue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardGroup {
                ForEach(Array(options.enumerated()), id: \.element) { index, option in
                    if index > 0 { RowDivider() }
                    optionRow(option)
                }
                if kind == .newUsers, project.posthog != nil {
                    RowDivider()
                    Button { choosingEvent = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle").font(.system(size: 20)).foregroundStyle(Palette.ink2).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("其他事件").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
                                Text("从项目的事件里挑一个").font(.system(size: 12)).foregroundStyle(Palette.ink2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.forward").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.ink2)
                        }
                        .frame(minHeight: 60)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("otherEvent")
                }
                if kind == .revenue, case .posthogEvent(let event, let property) = project.metrics.revenue {
                    HStack(spacing: 8) {
                        EventField(label: "事件", text: Binding(get: { event }, set: { project.metrics.revenue = .posthogEvent(event: $0, valueProperty: property) }))
                        EventField(label: "金额", text: Binding(get: { property }, set: { project.metrics.revenue = .posthogEvent(event: event, valueProperty: $0) }))
                    }
                    .padding(.bottom, 12)
                }
            }
            Text(kind == .newUsers
                 ? "注册事件和自定义事件按今天触发的人数算，不分来源；开始使用是今天第一次出现、之前 30 天没来过的人，按「算哪些人」里选的来源算。"
                 : "PostHog 付费事件把金额加起来，并能列出每一笔订单；RevenueCat 只给每天的总额。金额按美元显示。")
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
        }
        .task(id: project.metrics) { await measure() }
        .sheet(isPresented: $choosingEvent) {
            NavigationStack {
                EventPicker(project: project, purpose: .newUsers) { metric in
                    if case .event(let name, _) = metric { project.metrics.newUsers = .event(name) }
                }
            }
        }
    }

    private var options: [Option] {
        switch kind {
        case .newUsers:
            guard project.posthog != nil else { return [] }
            var list: [Option] = [.signup, .firstSeen]
            if case .event(let name) = project.metrics.newUsers, name != MetricSettings.signupEvent { list.append(.event(name)) }
            return list
        case .revenue:
            var list: [Option] = []
            if project.posthog != nil { list.append(.posthogRevenue) }
            if project.revenueCat != nil { list.append(.revenueCat) }
            return list + [.noRevenue]
        }
    }

    private var chosen: Option {
        switch kind {
        case .newUsers:
            switch project.metrics.newUsers {
            case .firstSeen: .firstSeen
            case .event(let name): name == MetricSettings.signupEvent ? .signup : .event(name)
            }
        case .revenue:
            switch project.metrics.revenue {
            case .posthogEvent: .posthogRevenue
            case .revenueCat: .revenueCat
            case .none: .noRevenue
            }
        }
    }

    private func optionRow(_ option: Option) -> some View {
        let selected = option == chosen
        return Button { choose(option) } label: {
            HStack(spacing: 12) {
                Circle()
                    .strokeBorder(selected ? Palette.ink : Palette.faint, lineWidth: 2)
                    .frame(width: 22, height: 22)
                    .overlay { if selected { Circle().fill(Palette.ink).frame(width: 12, height: 12) } }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(option)).font(.system(size: 16, weight: selected ? .bold : .semibold)).foregroundStyle(Palette.ink)
                    if let detail = detail(option) {
                        Text(verbatim: detail)
                            .font(detailIsCode(option) ? .system(size: 12).monospaced() : .system(size: 12))
                            .foregroundStyle(Palette.ink2)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if option != .noRevenue {
                    if loading && values[option] == nil {
                        ProgressView().controlSize(.small)
                    } else {
                        let metric: Metric = kind == .newUsers ? .newUsers : .revenue
                        Text(verbatim: metric.text(values[option]))
                            .font(Typeface.number(26))
                            .foregroundStyle(selected ? Palette.ink : Palette.ink2)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
            }
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func title(_ option: Option) -> LocalizedStringKey {
        switch option {
        case .signup: "注册事件"
        case .firstSeen: "开始使用"
        case .event: "自定义事件"
        case .posthogRevenue: "PostHog 事件"
        case .revenueCat: "RevenueCat"
        case .noRevenue: "不统计"
        }
    }

    private func detail(_ option: Option) -> String? {
        switch option {
        case .signup: MetricSettings.signupEvent
        case .firstSeen: String(localized: "今天第一次出现、之前 30 天没来过的人")
        case .event(let name): name
        case .posthogRevenue: nil
        case .revenueCat: String(localized: "RevenueCat 当日总额（UTC）")
        case .noRevenue: nil
        }
    }

    private func detailIsCode(_ option: Option) -> Bool {
        switch option {
        case .signup, .event: true
        default: false
        }
    }

    private func choose(_ option: Option) {
        switch option {
        case .signup: project.metrics.newUsers = .event(MetricSettings.signupEvent)
        case .firstSeen: project.metrics.newUsers = .firstSeen
        case .event(let name): project.metrics.newUsers = .event(name)
        case .posthogRevenue:
            if case .posthogEvent = project.metrics.revenue { return }
            project.metrics.revenue = .posthogEvent(event: "purchase", valueProperty: "value")
        case .revenueCat: project.metrics.revenue = .revenueCat
        case .noRevenue: project.metrics.revenue = .none
        }
    }

    /// Counts today's number every way at once. Typing an event name waits for a pause before asking again.
    private func measure() async {
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        let provider = model.provider
        let candidates: [(Option, Project)] = options.compactMap { option in
            var copy = project
            switch option {
            case .signup: copy.metrics.newUsers = .event(MetricSettings.signupEvent)
            case .firstSeen: copy.metrics.newUsers = .firstSeen
            case .event(let name): copy.metrics.newUsers = .event(name)
            case .posthogRevenue:
                if case .posthogEvent = copy.metrics.revenue {} else { copy.metrics.revenue = .posthogEvent(event: "purchase", valueProperty: "value") }
            case .revenueCat: copy.metrics.revenue = .revenueCat
            case .noRevenue: return nil
            }
            return (option, copy)
        }
        let metric: Metric = kind == .newUsers ? .newUsers : .revenue
        loading = true
        defer { loading = false }
        let measured = await withTaskGroup(of: (Option, Double?).self) { group in
            for (option, copy) in candidates {
                group.addTask { (option, try? await provider.measure(copy, metrics: [metric])[metric]) }
            }
            var found: [Option: Double] = [:]
            for await (option, value) in group { found[option] = value }
            return found
        }
        guard !Task.isCancelled else { return }
        values = measured
    }
}

/// A grey field with a small label, for an event or property name.
struct EventField: View {
    var label: LocalizedStringKey
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

/// "挑一个事件": the events the project sent in the last 7 days, most people first, with a search.
struct EventPicker: View {
    enum Purpose { case newUsers, metric, activity }

    var project: Project
    var purpose: Purpose
    var pick: (Metric) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var events: [EventStat] = []
    @State private var loading = true
    @State private var error: String?
    @State private var search = ""
    @State private var byPeople = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                BackButton()
                PageTitle(title: String(localized: "挑一个事件"), subtitle: subtitle)
                if purpose == .metric {
                    ChoiceBar(options: [(true, "数人数"), (false, "数次数")], selection: $byPeople)
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.ink2)
                    TextField("搜索事件", text: $search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("eventSearch")
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 46)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                }
                ErrorText(text: error)
                if !typed.isEmpty, !events.contains(where: { $0.name == typed }) {
                    CardGroup { eventRow(name: typed, value: nil) }
                }
                if purpose == .newUsers, !signupLike.isEmpty {
                    section(String(localized: "像注册的"), signupLike)
                }
                if !matching.isEmpty {
                    section(byPeople ? String(localized: "最常发生 · 近 7 天人数") : String(localized: "最常发生 · 近 7 天次数"), matching)
                }
            }
            .padding(16)
        }
        .sheetPage()
        .task { await load() }
    }

    private var subtitle: String {
        switch purpose {
        case .newUsers: String(localized: "新增用户按发过这个事件的人数算。右边是近 7 天的人数。")
        case .metric: String(localized: "右边是近 7 天的人数或次数。")
        case .activity: String(localized: "发过这个事件，才算用过一次。右边是近 7 天的人数。")
        }
    }

    private var typed: String { search.trimmingCharacters(in: .whitespaces) }

    private var filtered: [EventStat] {
        let query = typed.lowercased()
        let list = query.isEmpty ? events : events.filter { $0.name.lowercased().contains(query) }
        return byPeople ? list : list.sorted { $0.times > $1.times }
    }

    private var signupLike: [EventStat] { filtered.filter(\.looksLikeSignup) }

    private var matching: [EventStat] {
        purpose == .newUsers ? filtered.filter { !$0.looksLikeSignup } : filtered
    }

    private func section(_ title: String, _ list: [EventStat]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            CardGroup {
                ForEach(Array(list.prefix(60).enumerated()), id: \.element.id) { index, event in
                    if index > 0 { RowDivider() }
                    eventRow(name: event.name, value: byPeople ? event.people : event.times)
                }
            }
        }
    }

    private func eventRow(name: String, value: Int?) -> some View {
        Button {
            pick(.event(name, people: byPeople || purpose == .newUsers))
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(verbatim: value == nil ? String(localized: "用「\(name)」") : name)
                    .font(.system(size: 14, weight: .semibold).monospaced())
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let value {
                    Text(verbatim: Format.number(value)).font(Typeface.number(22)).foregroundStyle(Palette.ink)
                }
            }
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            events = try await model.provider.events(for: project)
        } catch {
            self.error = describe(error)
        }
    }
}
