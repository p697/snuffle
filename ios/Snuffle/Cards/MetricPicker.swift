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
    @Binding var measured: MeasuredNumbers
    var slot: CardSlot
    var layout: CardLayout
    var pick: (Metric) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var loading: Set<Metric> = []
    @State private var connecting: Platform?

    private enum Route: Hashable { case counting(CountingKind), events, definition }

    private var current: Metric? { layout[slot] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        PageTitle(title: current == nil ? String(localized: "加一个数") : String(localized: "换成哪个数"), subtitle: String(localized: "\(project.name) · 右边是现在的数，选了就是它"))
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
                case .definition: DefinitionPage(project: $project)
                case .events:
                    EventPicker(project: project, purpose: .metric) { metric in
                        Task { [project] in
                            if let values = try? await model.provider.measure(project, metrics: [metric]) { measured.add(values, countedAs: project.metrics) }
                        }
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
                    row(.newUsers)
                    ForEach([Metric.totalUsers, .activeToday, .activeWeek, .newWeek, .activeMonth, .online, .pageviews], id: \.self) { metric in
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
            if project.posthog != nil {
                // Under the numbers it changes.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: project.countingSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("countingLine")
                    NavigationLink(value: Route.definition) {
                        Text("改口径")
                            .font(.system(size: 13, weight: .bold))
                            .underline()
                            .foregroundStyle(Palette.ink)
                            .frame(minHeight: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("counting")
                }
                .padding(.horizontal, 6)
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
                RowDivider()
                if project.googlePlay != nil {
                    row(.crashRate)
                    RowDivider()
                    row(.anrRate)
                } else {
                    MissingSourceRow(titles: [Metric.crashRate, .anrRate].map(\.title).joined(separator: " · "), platform: .googlePlay) { connecting = .googlePlay }
                }
            }
        }
    }

    /// A library row; new users and revenue also link to how they are counted.
    @ViewBuilder
    private func row(_ metric: Metric, counting: CountingKind? = nil) -> some View {
        let available = metric.isAvailable(in: project)
        // A number already elsewhere on the card trades places with this one; an empty place takes it only when it
        // can move there (the only big number cannot).
        let onCard = metric != current && layout.metrics.contains(metric)
        let movable = !onCard || layout.placing(metric, at: slot) != layout
        VStack(alignment: .leading, spacing: 0) {
            MetricRow(
                title: metric.title(in: project),
                detail: onCard ? (current == nil ? String(localized: "已在卡片上，选它就挪到这里") : String(localized: "已在卡片上，选它就和这个数换位置")) : metric.explanation(in: project),
                value: available ? metric.text(value(metric)) : nil,
                loading: loading.contains(metric),
                selected: metric == current,
                enabled: available && movable
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
        measured.values(countedAs: project.metrics)[metric] ?? cached[metric]
    }

    /// The cache's numbers that mean the same under the counting being chosen.
    private var cached: [Metric: Double] {
        model.snapshot(project.id)?.values(countedAs: project.metrics) ?? [:]
    }

    private func choose(_ metric: Metric) {
        pick(metric)
        dismiss()
    }

    /// Reads what neither the cache nor an earlier read has for the counting being chosen: hourly numbers nobody
    /// showed yet, and every number that follows counting once it changed.
    private func measure() async {
        let library = Metric.fixed.filter { $0.isAvailable(in: project) }
        let settings = project.metrics
        let known = cached.merging(measured.values(countedAs: settings)) { $1 }
        let events = layout.metrics.filter { !$0.isShared }
        let missing = Set((library + events).filter { known[$0] == nil })
        guard !missing.isEmpty else { return }
        loading = missing
        let values = try? await model.provider.measure(project, metrics: missing)
        // Counting changed meanwhile: a newer read is on its way, and these numbers are for settings left behind.
        guard !Task.isCancelled else { return }
        loading = []
        if let values { measured.add(values, countedAs: settings) }
    }
}

/// Numbers the metric library read for a draft project, with the counting they were read under, so a number read
/// before the counting or scope changed is never shown for the new one.
struct MeasuredNumbers {
    private var countedAs: MetricSettings?
    private var values: [Metric: Double] = [:]

    func values(countedAs settings: MetricSettings) -> [Metric: Double] {
        countedAs == settings ? values : values.filter { !$0.key.followsCounting }
    }

    mutating func add(_ read: [Metric: Double], countedAs settings: MetricSettings) {
        values = values(countedAs: settings).merging(read) { $1 }
        countedAs = settings
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
