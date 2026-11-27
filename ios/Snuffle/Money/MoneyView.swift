import SnuffleKit
import SwiftUI

/// 收入: the total over the chosen days (the last 30 by default, as a day often has no sale), how it splits across
/// projects, the orders behind it and RevenueCat's subscription overview.
struct MoneyView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(RevenuePeriod.storageKey) private var period: RevenuePeriod = .month
    @State private var orders: [Order] = []
    @State private var overviews: [UUID: SubscriptionOverview] = [:]
    @State private var ordersError: String?
    @State private var overviewError: String?

    private var revenueProjects: [Project] {
        model.projects.filter { $0.metrics.revenue != .none }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ScreenTitle(title: String(localized: "收入"), subtitle: period.subtitle + " · " + String(localized: "全部项目 · 美元"))
                    ChoiceBar(options: RevenuePeriod.allCases.map { ($0, $0.label) }, selection: $period)
                        .accessibilityIdentifier("revenuePeriod")
                    hero
                    if !revenueProjects.isEmpty { split }
                    ordersSection
                    overviewSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .clearsTabBar()
            .background(Palette.paper)
            .toolbar(.hidden, for: .navigationBar)
            .task(id: OrdersRead(refresh: model.lastRefresh, days: period.days)) { await loadOrders() }
            .task(id: model.lastRefresh) { await loadOverviews() }
            .refreshable { await model.refreshAll() }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A month's total runs long: the number gets smaller before the "+$" beside it is squeezed.
            ViewThatFits(in: .horizontal) {
                total(size: 64)
                total(size: 50)
                total(size: 38)
            }
            summary
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func total(size: CGFloat) -> some View {
        let rise = model.marksFading ? nil : model.refreshMark?[period.revenue]
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Odometer(text: period.revenue.text(model.total(period.revenue)), size: size)
            DeltaChip(text: rise.map(period.revenue.delta), visible: rise != nil, size: 15).fixedSize()
        }
    }

    /// "13 笔订单 · 比前 30 天 ▼ 17% · 2 个项目有收入来源": each part only when it is known.
    private var summary: Text {
        guard !revenueProjects.isEmpty else {
            return Text("还没有项目连接收入来源，可以在项目设置里选择 PostHog 付费事件或 RevenueCat。")
        }
        var parts: [Text] = []
        let counts = revenueProjects.compactMap { model.snapshot($0.id)?[period.orders] }
        if !counts.isEmpty { parts.append(Text("\(Int(counts.reduce(0, +))) 笔订单")) }
        if let comparison = period.comparison, let change {
            parts.append(Text(comparison) + Text(verbatim: " ") + Text(change.text).fontWeight(.semibold).foregroundStyle(change.tone.color))
        }
        parts.append(Text("\(revenueProjects.count) 个项目有收入来源"))
        return parts.dropFirst().reduce(parts[0]) { $0 + Text(verbatim: " · ") + $1 }
    }

    /// The change on the same number of days before, across the projects that know both.
    private var change: Metric.ReferenceText? {
        let pairs = revenueProjects.compactMap { project -> (now: Double, before: Double)? in
            guard let snapshot = model.snapshot(project.id), let now = snapshot[period.revenue], let before = snapshot.previous[period.revenue] else { return nil }
            return (now, before)
        }
        guard !pairs.isEmpty else { return nil }
        return Metric.change(pairs.reduce(0) { $0 + $1.now }, from: pairs.reduce(0) { $0 + $1.before })
    }

    private var split: some View {
        let values = revenueProjects.map { ($0, model.snapshot($0.id)?[period.revenue] ?? 0) }
        let peak = max(1, values.map(\.1).max() ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(String(localized: "按项目"))
            CardGroup {
                ForEach(values, id: \.0.id) { project, revenue in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            ProjectBadge(project: project, size: 22)
                            Text(project.name).font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Text(Format.money(revenue)).font(Typeface.number(22))
                        }
                        GeometryReader { proxy in
                            Capsule().fill(Palette.pill)
                                .overlay(alignment: .leading) {
                                    // A refund can leave the days below nothing.
                                    Capsule().fill(Palette.ink).frame(width: max(6, proxy.size.width * max(0, revenue) / peak))
                                }
                        }
                        .frame(height: 8)
                        source(of: project)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink2)
                    }
                    .padding(.vertical, 10)
                    if project.id != values.last?.0.id { Divider().overlay(Palette.line) }
                }
            }
        }
    }

    /// "来自 RevenueCat · 3 笔".
    private func source(of project: Project) -> Text {
        let from = project.metrics.revenue == .revenueCat ? Text("来自 RevenueCat") : Text("来自 PostHog 付费事件")
        guard let count = model.snapshot(project.id)?[period.orders] else { return from }
        return from + Text(verbatim: " · ") + Text("\(Int(count)) 笔", comment: "Number of sales, after the revenue amount.")
    }

    @ViewBuilder
    private var ordersSection: some View {
        let error = ordersError ?? overviewError
        if !orders.isEmpty || error != nil {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(period.ordersTitle)
                CardGroup {
                    if let error {
                        Text(error).font(.system(size: 14)).foregroundStyle(Palette.bad).padding(.vertical, 12)
                    }
                    ForEach(orders.prefix(30)) { order in
                        OrderRow(order: order, project: model.projects.first { $0.id == order.projectId })
                        if order.id != orders.prefix(30).last?.id { Divider().overlay(Palette.line) }
                    }
                }
                if model.projects.contains(where: { $0.metrics.revenue == .revenueCat }) {
                    Text("RevenueCat 只提供每天的总额，没有逐笔订单，所以这里只列出 PostHog 付费事件。")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink2)
                        .padding(.horizontal, 6)
                }
            }
        }
    }

    @ViewBuilder
    private var overviewSection: some View {
        let entries = model.projects.compactMap { project in overviews[project.id].map { (project, $0) } }
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(String(localized: "订阅概况 · RevenueCat"))
                ForEach(entries, id: \.0.id) { project, overview in
                    CardGroup {
                        HStack {
                            ProjectBadge(project: project, size: 22)
                            Text(project.name).font(.system(size: 15, weight: .semibold))
                        }
                        .padding(.vertical, 10)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                            Stat(label: String(localized: "月经常性收入"), value: overview.mrr.map(Format.money) ?? "–")
                            Stat(label: String(localized: "在订人数"), value: overview.activeSubscriptions.map(Format.number) ?? "–")
                            Stat(label: String(localized: "试用中"), value: overview.activeTrials.map(Format.number) ?? "–")
                            Stat(label: String(localized: "近 28 天收入"), value: overview.revenueLast28Days.map(Format.money) ?? "–")
                        }
                        .padding(.bottom, 12)
                    }
                }
            }
        }
    }

    private func loadOrders() async {
        ordersError = nil
        var collected: [Order] = []
        for project in model.refreshable where project.metrics.revenue != .none {
            do {
                collected += try await model.provider.orders(for: project, days: period.days)
            } catch {
                ordersError = describe(error)
            }
        }
        orders = collected.sorted { $0.date > $1.date }
    }

    private func loadOverviews() async {
        overviewError = nil
        var collected: [UUID: SubscriptionOverview] = [:]
        for project in model.refreshable where project.metrics.revenue != .none {
            do {
                if let overview = try await model.provider.overview(for: project) { collected[project.id] = overview }
            } catch {
                overviewError = describe(error)
            }
        }
        overviews = collected
    }
}

/// The days the 收入 tab adds up, counting today.
enum RevenuePeriod: String, CaseIterable {
    case today, week, month

    /// The choice is kept on the phone, in the standard defaults.
    static let storageKey = "revenuePeriod"

    var days: Int {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        }
    }

    var revenue: Metric { Metric.revenues[Self.allCases.firstIndex(of: self)!] }
    var orders: Metric { Metric.ordersByWindow[Self.allCases.firstIndex(of: self)!] }

    var label: LocalizedStringKey {
        switch self {
        case .today: "今天"
        case .week: "7 天"
        case .month: "30 天"
        }
    }

    var subtitle: String {
        switch self {
        case .today: String(localized: "今天")
        case .week: String(localized: "近 7 天")
        case .month: String(localized: "近 30 天")
        }
    }

    /// What the change is against; today is set against nothing.
    var comparison: LocalizedStringKey? {
        switch self {
        case .today: nil
        case .week: "比前 7 天"
        case .month: "比前 30 天"
        }
    }

    var ordersTitle: String {
        switch self {
        case .today: String(localized: "今天的订单")
        case .week: String(localized: "近 7 天的订单")
        case .month: String(localized: "近 30 天的订单")
        }
    }
}

/// What the orders list was read for: it is read again after a refresh or when the days change.
private struct OrdersRead: Equatable {
    var refresh: Date?
    var days: Int
}

private struct OrderRow: View {
    var order: Order
    var project: Project?

    var body: some View {
        HStack(spacing: 12) {
            // The time today, with the day in front on an earlier day.
            Text(Format.moment(order.date))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.ink2)
                .fixedSize()
                .frame(minWidth: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(order.product ?? String(localized: "订单")).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text([project?.name, Format.place(order.country)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink2)
            }
            Spacer()
            Text(Format.money(order.amount)).font(Typeface.number(22))
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

struct Stat: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.ink2)
            Text(value).font(Typeface.number(26)).foregroundStyle(Palette.ink)
        }
        .accessibilityElement(children: .combine)
    }
}
