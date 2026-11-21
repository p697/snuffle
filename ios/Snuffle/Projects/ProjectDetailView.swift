import Charts
import SnuffleKit
import SwiftUI

/// One project: today's numbers, a 7- or 30-day history, and where each number comes from.
struct ProjectDetailView: View {
    var project: Project
    @Environment(AppModel.self) private var model
    @Environment(\.openPaywall) private var openPaywall
    @Environment(\.dismiss) private var dismiss
    @State private var range = Range.today
    @State private var history: [DailyPoint] = []
    @State private var loading = false
    @State private var historyError: String?
    @State private var editing = false

    enum Range: String, CaseIterable, Identifiable {
        case today = "今天"
        case week = "7 天"
        case month = "30 天"
        var id: String { rawValue }
        var days: Int { self == .week ? 7 : 30 }
    }

    private var snapshot: ProjectSnapshot? { model.snapshot(project.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Picker("范围", selection: Binding(get: { range }, set: select)) {
                    ForEach(Range.allCases) { item in
                        Text(item == .month && !model.pro.isPro && !model.settings.demoMode ? "30 天 · Pro" : item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                if range == .today {
                    today
                } else {
                    historyView
                }
                sources
            }
            .padding(16)
        }
        .clearsTabBar()
        .background(Palette.paper)
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.settings.demoMode {
                Button("编辑") { editing = true }
            }
        }
        .sheet(isPresented: $editing) { ProjectEditor(project: project) }
        // Deleted from the editor: leave the page instead of showing an empty one.
        .onChange(of: model.workspace.projects.contains { $0.id == project.id }) { _, exists in
            if !exists { dismiss() }
        }
        .task(id: range) { await loadHistory() }
    }

    private func select(_ next: Range) {
        if next == .month && !model.pro.isPro && !model.settings.demoMode {
            openPaywall(.history)
            return
        }
        range = next
    }

    private var header: some View {
        HStack(spacing: 12) {
            ProjectBadge(project: project, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(Typeface.title(24))
                Text(snapshot.map { "更新于 \(Format.ago($0.fetchedAt))" } ?? "还没刷新过")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink2)
            }
        }
    }

    private var today: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("今日新增用户").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink2)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Odometer(text: snapshot?.newUsers.map(Format.number) ?? "–", size: 72)
                    if let yesterday = snapshot?.newUsersYesterday, let now = snapshot?.newUsers {
                        let diff = now - yesterday
                        Text(diff == 0 ? "和昨天此时一样" : diff > 0 ? "比昨天此时多 \(Format.number(diff))" : "比昨天此时少 \(Format.number(-diff))")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(diff == 0 ? Palette.ink2 : diff > 0 ? Palette.up : Palette.bad)
                    }
                }
                HourBars(values: snapshot?.hourlyNewUsers ?? []).frame(height: 56)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                if project.metrics.revenue != .none {
                    tile("收入", snapshot?.revenue.map(Format.money) ?? "–", note: revenueNote)
                }
                tile("今天活跃", snapshot?.active.map(Format.number) ?? "–", note: "PostHog 里今天有动作的人")
                if let extra = snapshot?.extra {
                    tile(extra.label.replacingOccurrences(of: "次", with: ""), Format.number(extra.value), note: "今天")
                }
                if project.hasStore {
                    tile("待回复评论", snapshot?.reviewsToAnswer.map(String.init) ?? "–", note: storeNote)
                }
                tile("此刻在线", snapshot?.online.map(Format.number) ?? "–", note: "最近一分钟")
            }
        }
    }

    private var revenueNote: String {
        if project.metrics.revenue == .revenueCat { return "RevenueCat 当日总额（UTC）" }
        return snapshot?.sales.map { "\($0) 笔 · PostHog 付费事件" } ?? "PostHog 付费事件"
    }

    private var storeNote: String {
        [project.appStore != nil ? "App Store" : nil, project.googlePlay != nil ? "Google Play" : nil].compactMap { $0 }.joined(separator: " + ")
    }

    private func tile(_ label: String, _ value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink2)
            Text(value).font(Typeface.number(32)).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.6)
            Text(note).font(.system(size: 11)).foregroundStyle(Palette.ink2).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var historyView: some View {
        VStack(alignment: .leading, spacing: 12) {
            chart(title: "每日新增用户", total: history.compactMap(\.newUsers).reduce(0, +).formatted()) { point in
                BarMark(x: .value("日期", point.day, unit: .day), y: .value("新增", point.newUsers ?? 0))
                    .foregroundStyle(Palette.ink)
                    .cornerRadius(3)
            }
            if history.contains(where: { $0.revenue != nil }) {
                chart(title: "每日收入", total: Format.money(history.compactMap(\.revenue).reduce(0, +))) { point in
                    BarMark(x: .value("日期", point.day, unit: .day), y: .value("收入", point.revenue ?? 0))
                        .foregroundStyle(Palette.up)
                        .cornerRadius(3)
                }
            }
            chart(title: "每日活跃", total: Format.number(Int(Double(history.compactMap(\.active).reduce(0, +)) / Double(max(1, history.count)))) + " / 天") { point in
                LineMark(x: .value("日期", point.day, unit: .day), y: .value("活跃", point.active ?? 0))
                    .foregroundStyle(Palette.ink)
                    .interpolationMethod(.monotone)
            }
            if let historyError {
                Text(historyError).font(.system(size: 13)).foregroundStyle(Palette.bad)
            }
        }
        .overlay {
            if loading && history.isEmpty { ProgressView() }
        }
    }

    private func chart<Mark: ChartContent>(title: String, total: String, @ChartContentBuilder mark: @escaping (DailyPoint) -> Mark) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink2)
                Spacer()
                Text(total).font(Typeface.number(24))
            }
            Chart(history) { point in mark(point) }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: range == .week ? 1 : 7)) { _ in
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(Palette.line)
                        AxisValueLabel()
                    }
                }
                .frame(height: 150)
        }
        .padding(16)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("数据来自")
            CardGroup {
                ForEach(project.platforms) { platform in
                    let failure = snapshot?.failures.first { $0.platform == platform }
                    HStack(spacing: 12) {
                        PlatformLogo(platform: platform, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(platform.displayName).font(.system(size: 15, weight: .semibold))
                            Text(failure?.message ?? detail(platform))
                                .font(.system(size: 12))
                                .foregroundStyle(failure == nil ? Palette.ink2 : Palette.bad)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private func detail(_ platform: Platform) -> String {
        switch platform {
        case .posthog: project.posthog.map { "项目 \($0.projectName) · 时区 \($0.timeZone)" } ?? ""
        case .revenueCat: project.revenueCat.map { "项目 \($0.projectName)" } ?? ""
        case .appStore: project.appStore.map { "\($0.appName) · \($0.bundleId)" } ?? ""
        case .googlePlay: project.googlePlay.map { "\($0.packageName) · 只能读到近 7 天的评论" } ?? ""
        }
    }

    private func loadHistory() async {
        guard range != .today else { return }
        loading = true
        historyError = nil
        defer { loading = false }
        do {
            history = try await model.provider.history(for: project, days: range.days)
        } catch {
            historyError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
