import SnuffleKit
import SwiftUI

/// 收入: today's total, how it splits across projects, today's orders and RevenueCat's subscription overview.
struct MoneyView: View {
    @Environment(AppModel.self) private var model
    @State private var orders: [Order] = []
    @State private var overviews: [UUID: SubscriptionOverview] = [:]
    @State private var loadError: String?

    private var revenueProjects: [Project] {
        model.projects.filter { $0.metrics.revenue != .none }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ScreenTitle(title: String(localized: "收入"), subtitle: String(localized: "今天 · 全部项目 · 美元"))
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
            .task(id: model.lastRefresh) { await load() }
            .refreshable { await model.refreshAll() }
        }
    }

    private var hero: some View {
        let rise = model.marksFading ? nil : model.refreshMark?[.revenue]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Odometer(text: Metric.revenue.text(model.total(.revenue)), size: 64)
                DeltaChip(text: rise.map(Metric.revenue.delta), visible: rise != nil, size: 15)
            }
            Text(revenueProjects.isEmpty ? String(localized: "还没有项目连接收入来源，可以在项目设置里选择 PostHog 付费事件或 RevenueCat。") : String(localized: "\(salesCount) 笔订单") + " · " + String(localized: "\(revenueProjects.count) 个项目有收入来源"))
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var salesCount: Int {
        revenueProjects.compactMap { model.snapshot($0.id)?.orders }.reduce(0, +)
    }

    private var split: some View {
        let values = revenueProjects.map { ($0, model.snapshot($0.id)?.revenue ?? 0) }
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
                                    Capsule().fill(Palette.ink).frame(width: max(6, proxy.size.width * revenue / peak))
                                }
                        }
                        .frame(height: 8)
                        Text(project.metrics.revenue == .revenueCat ? "来自 RevenueCat 当日总额" : "来自 PostHog 付费事件")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink2)
                    }
                    .padding(.vertical, 10)
                    if project.id != values.last?.0.id { Divider().overlay(Palette.line) }
                }
            }
        }
    }

    @ViewBuilder
    private var ordersSection: some View {
        if !orders.isEmpty || loadError != nil {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(String(localized: "今天的订单"))
                CardGroup {
                    if let loadError {
                        Text(loadError).font(.system(size: 14)).foregroundStyle(Palette.bad).padding(.vertical, 12)
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

    private func load() async {
        loadError = nil
        var collected: [Order] = []
        var collectedOverviews: [UUID: SubscriptionOverview] = [:]
        for project in model.refreshable where project.metrics.revenue != .none {
            do {
                collected += try await model.provider.orders(for: project)
                if let overview = try await model.provider.overview(for: project) { collectedOverviews[project.id] = overview }
            } catch {
                loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        orders = collected.sorted { $0.date > $1.date }
        overviews = collectedOverviews
    }
}

private struct OrderRow: View {
    var order: Order
    var project: Project?

    var body: some View {
        HStack(spacing: 12) {
            Text(Format.clock(order.date))
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
