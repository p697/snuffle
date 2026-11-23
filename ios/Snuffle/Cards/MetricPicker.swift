import SnuffleKit
import SwiftUI

/// One row of the metric library: what it counts, and the number it would show right now.
struct MetricRow: View {
    var title: String
    var detail: String
    var value: String?
    var loading = false
    var selected = false
    var enabled = true
    var action: () -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: title)
                            .font(.system(size: 16, weight: selected ? .bold : .semibold))
                            .foregroundStyle(enabled ? Palette.ink : Palette.ink2)
                        if selected {
                            Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(Palette.ink)
                        }
                    }
                    Text(verbatim: detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if loading {
                    ProgressView().controlSize(.small)
                } else if let value {
                    Text(verbatim: value)
                        .font(Typeface.number(26))
                        .foregroundStyle(enabled ? Palette.ink : Palette.ink2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 2)
                        .background(alignment: .bottom) {
                            if selected && value != "–" { Rectangle().fill(accent).frame(height: 10).padding(.bottom, 3) }
                        }
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// "这个项目还没连 RevenueCat": numbers a source would add, and the way to connect it.
private struct MissingSourceRow: View {
    var titles: String
    var platform: Platform
    var connect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: titles).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink2)
                Text("这个项目还没连 \(platform.displayName)").font(.system(size: 12)).foregroundStyle(Palette.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("去连接", action: connect)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .overlay(Capsule().strokeBorder(Palette.ink, lineWidth: 1.5))
                .buttonStyle(.plain)
        }
        .frame(minHeight: 68)
    }
}

/// The library for one slot of a project's card. Every row shows this project's number now, so the choice is made
/// by what it shows; numbers not read yet are read when the library opens.
struct CardMetricPicker: View {
    @Binding var project: Project
    /// Shared with the card editor, so its preview shows what the library read.
    @Binding var measured: [Metric: Double]
    var slot: CardSlot
    var layout: CardLayout
    var pick: (Metric) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var loading: Set<Metric> = []
    @State private var connecting: Platform?

    private enum Route: Hashable { case counting(CountingKind), events, scope }

    private var current: Metric? {
        switch slot {
        case .big(let index): layout.big[safe: index]
        case .small(let index): layout.small[safe: index]
        case .add: nil
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        PageTitle(title: slot == .add ? String(localized: "加一个小数") : String(localized: "换成哪个数"), subtitle: String(localized: "\(project.name) · 右边是现在的数，选了就是它"))
                        RoundIconButton(systemName: "xmark", label: String(localized: "关闭")) { dismiss() }
                    }
                    usersSection
                    revenueSection
                    storeSection
                }
                .padding(16)
            }
            .sheetPage()
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .counting(let kind): CountingPage(kind: kind, project: $project)
                case .scope: ScopePage(project: $project)
                case .events:
                    EventPicker(project: project, purpose: .metric) { metric in
                        Task { if let values = try? await model.provider.measure(project, metrics: [metric]) { measured.merge(values) { $1 } } }
                        choose(metric)
                    }
                }
            }
        }
        .task(id: project.metrics) { await measure() }
        .sheet(item: $connecting) { platform in ConnectSourceSheet(platform: platform, project: $project) }
    }

    // MARK: Sections

    @ViewBuilder
    private var usersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(String(localized: "用户 · PostHog"))
            CardGroup {
                if project.posthog == nil {
                    MissingSourceRow(titles: String(localized: "新增用户 · 活跃 · 在线 · 事件"), platform: .posthog) { connecting = .posthog }
                } else {
                    NavigationLink(value: Route.scope) {
                        HStack(spacing: 12) {
                            Image(systemName: "person.2").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("算哪些人").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
                                Text(verbatim: project.scopeSummary).font(.system(size: 12)).foregroundStyle(Palette.ink2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.forward").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.ink2)
                        }
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("scope")
                    RowDivider()
                    row(.newUsers, counting: .newUsers)
                    ForEach([Metric.activeToday, .activeWeek, .activeMonth, .totalUsers, .online, .pageviews], id: \.self) { metric in
                        RowDivider()
                        row(metric)
                    }
                    // Events already on this card, so the slot's own event shows as chosen.
                    ForEach(layout.metrics.filter { !$0.isShared }, id: \.self) { metric in
                        RowDivider()
                        row(metric)
                    }
                    RowDivider()
                    NavigationLink(value: Route.events) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("任意事件").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
                                Text("从项目的事件里挑一个，数人数或次数").font(.system(size: 12)).foregroundStyle(Palette.ink2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.forward").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.ink2)
                        }
                        .frame(minHeight: 60)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("anyEvent")
                }
            }
        }
    }

    @ViewBuilder
    private var revenueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(String(localized: "收入"))
            CardGroup {
                if project.posthog == nil && project.revenueCat == nil {
                    MissingSourceRow(titles: String(localized: "收入 · MRR · 订阅"), platform: .revenueCat) { connecting = .revenueCat }
                } else {
                    row(.revenue, counting: .revenue)
                    if Metric.orders.isAvailable(in: project) {
                        RowDivider()
                        row(.orders)
                    }
                    RowDivider()
                    if project.revenueCat == nil {
                        MissingSourceRow(titles: [Metric.mrr, .activeSubscriptions, .activeTrials, .revenueLast28Days].map(\.title).joined(separator: " · "), platform: .revenueCat) { connecting = .revenueCat }
                    } else {
                        ForEach(Array([Metric.mrr, .activeSubscriptions, .activeTrials, .revenueLast28Days].enumerated()), id: \.offset) { index, metric in
                            if index > 0 { RowDivider() }
                            row(metric)
                        }
                    }
                }
            }
        }
    }

    private var storeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(String(localized: "商店"))
            CardGroup {
                if project.hasStore {
                    row(.reviewsToAnswer)
                } else {
                    MissingSourceRow(titles: Metric.reviewsToAnswer.title, platform: .appStore) { connecting = .appStore }
                }
            }
        }
    }

    /// A library row; new users and revenue also link to how they are counted.
    @ViewBuilder
    private func row(_ metric: Metric, counting: CountingKind? = nil) -> some View {
        let available = metric.isAvailable(in: project)
        // A big slot takes any number (one already on the card swaps places); a pill cannot take a big number.
        let elsewhere: Bool = {
            guard metric != current, layout.metrics.contains(metric) else { return false }
            switch slot {
            case .big: return false
            case .small: return layout.big.contains(metric)
            case .add: return true
            }
        }()
        // PostHog counts only people who signed in; a project without any has no total to show.
        let nobody = metric == .totalUsers && metric != current && value(metric) == 0
        VStack(alignment: .leading, spacing: 0) {
            MetricRow(
                title: metric.title,
                detail: elsewhere ? String(localized: "已在卡片上") : nobody ? String(localized: "这个项目还没有登录过的人，PostHog 数不出累计用户") : metric.explanation(in: project),
                value: available ? metric.text(value(metric)) : nil,
                loading: loading.contains(metric),
                selected: metric == current,
                enabled: available && !elsewhere && !nobody
            ) { choose(metric) }
            if let counting {
                NavigationLink(value: Route.counting(counting)) {
                    Text("改口径")
                        .font(.system(size: 13, weight: .bold))
                        .underline()
                        .foregroundStyle(Palette.ink)
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, -10)
                .padding(.bottom, 4)
            }
        }
    }

    private func value(_ metric: Metric) -> Double? {
        measured[metric] ?? model.snapshot(project.id)?[metric]
    }

    private func choose(_ metric: Metric) {
        pick(metric)
        dismiss()
    }

    /// Reads what the cache does not have (hourly numbers nobody showed yet, counting just changed).
    private func measure() async {
        let library = Metric.fixed.filter { $0.isAvailable(in: project) }
        let cached = model.snapshot(project.id)
        let original = model.projects.first { $0.id == project.id }
        let countingChanged = original?.metrics != project.metrics
        let events = layout.metrics.filter { !$0.isShared }
        let missing = Set((library + events).filter { (measured[$0] == nil && cached?[$0] == nil) || (countingChanged && $0.followsCounting) })
        guard !missing.isEmpty else { return }
        loading = missing
        defer { loading = [] }
        if let values = try? await model.provider.measure(project, metrics: missing) {
            measured.merge(values) { $1 }
        }
    }
}

// MARK: Totals

/// "调整合计": the three numbers in the totals strip, each added up across projects.
struct TotalsEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var totals: [Metric] = []
    @State private var picking: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    RoundIconButton(systemName: "xmark", label: String(localized: "取消")) { dismiss() }
                    Spacer()
                    Text("顶部合计").font(.system(size: 17, weight: .heavy)).foregroundStyle(Palette.ink)
                    Spacer()
                    Button("完成") {
                        model.saveTotals(totals)
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(Palette.paper)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(Palette.ink, in: Capsule())
                }
                Text("点一个数换掉它。每个数是所有项目加起来的。")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.ink2)
                    .padding(.horizontal, 4)
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(totals.enumerated()), id: \.offset) { index, metric in
                        Button { picking = index } label: {
                            TotalTile(metric: metric, value: model.total(metric), rise: nil)
                                .padding(10)
                                .background(picking == index ? Color.white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(Palette.stripMuted, style: StrokeStyle(lineWidth: 1.5, dash: picking == index ? [] : [5, 4]))
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("换成别的数")
                        .accessibilityIdentifier("totalTile-\(index)")
                    }
                }
                .padding(10)
                .background(Palette.strip, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                Button("恢复默认") { withAnimation(.snappy) { totals = CardLayout.standardTotals } }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(16)
        }
        .background(Palette.paper.ignoresSafeArea())
        .onAppear { if totals.isEmpty { totals = model.settings.totals } }
        .sheet(item: Binding(get: { picking.map(TotalSlot.init) }, set: { picking = $0?.index })) { slot in
            TotalsMetricPicker(current: totals[slot.index], taken: totals) { metric in
                if let other = totals.firstIndex(of: metric) { totals.swapAt(slot.index, other) } else { totals[slot.index] = metric }
            }
        }
    }

    private struct TotalSlot: Identifiable {
        var index: Int
        var id: Int { index }
    }
}

/// The library for the totals strip: numbers every project shares, added up.
private struct TotalsMetricPicker: View {
    var current: Metric
    var taken: [Metric]
    var pick: (Metric) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var measured: [Metric: Double] = [:]
    @State private var loading: Set<Metric> = []

    private static let sections: [(LocalizedStringKey, [Metric])] = [
        ("用户 · PostHog", [.newUsers, .activeToday, .activeWeek, .activeMonth, .totalUsers, .online, .pageviews]),
        ("收入", [.revenue, .orders, .mrr, .activeSubscriptions, .activeTrials, .revenueLast28Days]),
        ("商店", [.reviewsToAnswer])
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    PageTitle(title: String(localized: "换成哪个数"), subtitle: String(localized: "全部项目加起来 · 右边是现在的数"))
                    RoundIconButton(systemName: "xmark", label: String(localized: "关闭")) { dismiss() }
                }
                ForEach(Self.sections.indices, id: \.self) { index in
                    let metrics = Self.sections[index].1.filter { metric in metric == current || model.projects.contains { metric.isAvailable(in: $0) } }
                    if !metrics.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Self.sections[index].0)
                                .font(.system(size: 12, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(Palette.ink2)
                                .padding(.horizontal, 6)
                            CardGroup {
                                ForEach(Array(metrics.enumerated()), id: \.offset) { position, metric in
                                    if position > 0 { RowDivider() }
                                    MetricRow(
                                        title: metric.title,
                                        detail: projectsLine(metric),
                                        value: metric.text(total(metric)),
                                        loading: loading.contains(metric),
                                        selected: metric == current
                                    ) {
                                        pick(metric)
                                        dismiss()
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Palette.paper.ignoresSafeArea())
        .task { await measure() }
    }

    private func projectsLine(_ metric: Metric) -> String {
        let count = model.projects.filter { metric.isAvailable(in: $0) }.count
        let place = taken.contains(metric) && metric != current ? String(localized: "已在合计里") + " · " : ""
        return place + String(localized: "\(count) 个项目有这个数")
    }

    private func total(_ metric: Metric) -> Double? {
        measured[metric] ?? model.total(metric)
    }

    /// Adds up what the cache does not have yet, project by project.
    private func measure() async {
        let library = Self.sections.flatMap(\.1)
        let missing = library.filter { model.total($0) == nil && model.projects.contains(where: $0.isAvailable(in:)) }
        guard !missing.isEmpty else { return }
        loading = Set(missing)
        defer { loading = [] }
        let provider = model.provider
        let projects = model.refreshable
        let results = await withTaskGroup(of: [Metric: Double].self) { group in
            for project in projects {
                group.addTask { (try? await provider.measure(project, metrics: Set(missing))) ?? [:] }
            }
            var sum: [Metric: Double] = [:]
            for await values in group { sum.merge(values, uniquingKeysWith: +) }
            return sum
        }
        measured.merge(results) { $1 }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
