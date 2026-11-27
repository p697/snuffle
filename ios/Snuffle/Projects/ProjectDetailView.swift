import Charts
import SnuffleKit
import SwiftUI

/// One project's board, the phone version of its PostHog dashboard: the four people numbers (tap one for how it is
/// counted), the platform split, a chart per number by platform, the charts picked from its own dashboards, and
/// everything else it reads.
struct ProjectDetailView: View {
    var project: Project
    @Environment(AppModel.self) private var model
    @Environment(\.openPaywall) private var openPaywall
    @Environment(\.dismiss) private var dismiss
    /// The range picked; until then 30 days with Pro, 7 without.
    @State private var picked: Int?
    @State private var loading = false
    @State private var boardError: String?
    @State private var pinFailures: [Int: String] = [:]
    @State private var editing = false
    @State private var editingCard = false
    @State private var editingCounting = false
    @State private var pickingCharts = false
    @State private var sheetMetric: Metric?

    /// The saved project, which the editors change after this page opened.
    private var current: Project { model.projects.first { $0.id == project.id } ?? project }
    private var snapshot: ProjectSnapshot? { model.snapshot(project.id) }
    private var board: ProjectBoard? { model.boards[project.id]?[days] }
    private var canSeeMonth: Bool { model.pro.isPro || model.settings.demoMode }
    private var days: Int { picked ?? (canSeeMonth ? 30 : 7) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                heroes
                if let platforms = snapshot?.platforms, !platforms.isEmpty {
                    PlatformCard(platforms: platforms)
                }
                if current.posthog != nil {
                    rangePicker
                    charts
                    pins
                }
                others
                sources
            }
            .padding(16)
        }
        .clearsTabBar()
        .background(Palette.paper)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.settings.demoMode {
                if current.posthog != nil {
                    Button("口径") { editingCounting = true }
                        .accessibilityIdentifier("editCounting")
                }
                Button("调整卡片", systemImage: "slider.horizontal.3") { editingCard = true }
                    .accessibilityIdentifier("editCard")
                Button("编辑") { editing = true }
            }
        }
        .refreshable {
            await model.refresh([current], trigger: .project)
        }
        .sheet(isPresented: $editing) { ProjectEditor(project: current) }
        .sheet(isPresented: $editingCard) { CardEditor(project: current) }
        .sheet(isPresented: $editingCounting) { CountingEditor(project: current) }
        .sheet(isPresented: $pickingCharts) { ChartPicker(project: current) }
        .sheet(item: $sheetMetric) { metric in MetricSheet(project: current, metric: metric) }
        // Deleted from the editor: leave the page instead of showing an empty one.
        .onChange(of: model.workspace.projects.contains { $0.id == project.id }) { _, exists in
            if !exists { dismiss() }
        }
        .task(id: BoardKey(days: days, refreshed: model.lastRefresh, counting: current.metrics)) { await loadBoard() }
        .task(id: PinsKey(refreshed: model.lastRefresh, pins: current.pins.map(\.id))) { await runPins() }
    }

    private struct BoardKey: Equatable { var days: Int; var refreshed: Date?; var counting: MetricSettings }
    private struct PinsKey: Equatable { var refreshed: Date?; var pins: [Int] }

    // MARK: Header and numbers

    private var header: some View {
        HStack(spacing: 12) {
            ProjectBadge(project: current, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(current.name).font(Typeface.title(24))
                Text(statusLine)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "刚刚更新 · 按 UTC 计日 · 按看板「Launch」算".
    private var statusLine: String {
        var parts = [snapshot.map { String(localized: "更新于 \(Format.ago($0.fetchedAt))") } ?? String(localized: "还没刷新过")]
        if let zone = current.dayZoneLabel { parts.append(String(localized: "按 \(zone) 计日")) }
        if current.posthog != nil { parts.append(current.countingSummary) }
        return parts.joined(separator: " · ")
    }

    /// The four people numbers, or for a project without PostHog whatever its card shows.
    private var heroMetrics: [Metric] {
        let people = MetricsInUse.board.filter { $0.isAvailable(in: current) }
        return people.isEmpty ? Array(current.card.visible(in: current).metrics.prefix(4)) : people
    }

    private var heroes: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(heroMetrics, id: \.self) { metric in
                Button { sheetMetric = metric } label: { NumberTile(project: current, metric: metric, snapshot: snapshot) }
                    .buttonStyle(.plain)
                    .accessibilityHint("看这个数怎么算")
                    .accessibilityIdentifier("tile-\(metric.id)")
            }
        }
    }

    // MARK: Charts

    private var rangePicker: some View {
        Picker("范围", selection: Binding(get: { days }, set: select)) {
            Text("7 天").tag(7)
            Text(canSeeMonth ? "30 天" : "30 天 · Pro").tag(30)
        }
        .pickerStyle(.segmented)
    }

    private func select(_ next: Int) {
        if next == 30 && !canSeeMonth {
            openPaywall(.history)
            return
        }
        picked = next
    }

    @ViewBuilder
    private var charts: some View {
        if let board {
            let zone = current.zone
            if board.days.contains(where: { !$0.total.isEmpty }) {
                StackedChart(
                    title: String(localized: "累计 · 按平台"),
                    note: String(localized: "每天结束时一共有多少，今天到现在为止"),
                    bars: board.days.map { StackedChart.Bar(label: Format.day($0.day, in: zone), parts: $0.total) },
                    platforms: board.platforms
                )
            }
            StackedChart(
                title: String(localized: "每日活跃 · 按平台"),
                note: Metric.activeToday.explanation(in: current),
                bars: board.days.map { StackedChart.Bar(label: Format.day($0.day, in: zone), parts: $0.active) },
                platforms: board.platforms
            )
            StackedChart(
                title: String(localized: "每日新增 · 按平台"),
                note: Metric.newUsers.explanation(in: current),
                bars: board.days.map { StackedChart.Bar(label: Format.day($0.day, in: zone), parts: $0.new) },
                platforms: board.platforms
            )
            if !board.weeks.isEmpty {
                StackedChart(
                    title: String(localized: "每周活跃 · 新 / 老"),
                    note: String(localized: "每周用过的里面，第一次来的和回来的；这周还没过完"),
                    bars: board.weeks.map { StackedChart.Bar(label: Format.day($0.start, in: zone), parts: ["new": $0.new, "returning": $0.returning]) },
                    platforms: ["returning", "new"],
                    names: ["new": String(localized: "新"), "returning": String(localized: "老")],
                    colors: ["new": Palette.ink, "returning": Color(light: 0x8A8A80, dark: 0x6E6E66)]
                )
            }
            if board.hasRevenue {
                StackedChart(
                    title: String(localized: "每日收入"),
                    note: Metric.revenue.explanation(in: current),
                    bars: board.days.map { StackedChart.Bar(label: Format.day($0.day, in: zone), parts: ["revenue": Int(($0.revenue ?? 0).rounded())]) },
                    platforms: ["revenue"],
                    names: ["revenue": Metric.revenue.title],
                    colors: ["revenue": Palette.up],
                    money: true
                )
            }
        } else if loading {
            ProgressView().frame(maxWidth: .infinity, minHeight: 160)
        }
        if let boardError {
            ErrorText(text: boardError)
        }
    }

    private func loadBoard() async {
        guard current.posthog != nil || current.revenueCat != nil else { return }
        loading = true
        defer { loading = false }
        do {
            try await model.loadBoard(current, days: days)
            boardError = nil
        } catch {
            if !Task.isCancelled { boardError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    // MARK: Charts from the project's dashboards

    @ViewBuilder
    private var pins: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("来自你的看板").font(.system(size: 18, weight: .heavy)).foregroundStyle(Palette.ink)
                    Text("原样跑你在 PostHog 里写的查询").font(.system(size: 12)).foregroundStyle(Palette.ink2)
                }
                Spacer()
                if !model.settings.demoMode {
                    Button(current.pins.isEmpty ? String(localized: "添加") : String(localized: "管理")) { pickingCharts = true }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Palette.ink)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("pickCharts")
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 4)
            if current.pins.isEmpty {
                Button { pickingCharts = true } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2").font(.system(size: 22)).foregroundStyle(Palette.ink2)
                        Text("把 PostHog 看板里的图放到这里").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                        Text("比如付费转化、崩溃率这些只有你的项目才有的图").font(.system(size: 12)).foregroundStyle(Palette.ink2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.faint, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.settings.demoMode)
            }
            ForEach(current.pins) { tile in
                InsightCard(project: current, tile: tile, result: model.insightResults[tile.id], failure: pinFailures[tile.id])
            }
        }
    }

    private func runPins() async {
        guard !current.pins.isEmpty else { return }
        let failures = await model.runPins(current)
        pinFailures = failures.mapValues { ($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription }
    }

    // MARK: Everything else

    /// Numbers the project reads besides the four above: revenue, orders, subscriptions, reviews.
    private var otherMetrics: [Metric] {
        let shown = Set(heroMetrics)
        let library = Metric.fixed.filter { !shown.contains($0) && $0.isAvailable(in: current) && snapshot?[$0] != nil && !$0.isScoped && $0 != .newWeek }
        let card = current.card.metrics.filter { !shown.contains($0) && $0.isAvailable(in: current) }
        var seen = Set<Metric>()
        return (card + library).filter { seen.insert($0).inserted }
    }

    @ViewBuilder
    private var others: some View {
        if !otherMetrics.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(String(localized: "其他"))
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(otherMetrics, id: \.self) { metric in
                        NumberTile(project: current, metric: metric, snapshot: snapshot, compact: true)
                    }
                }
            }
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(String(localized: "数据来自"))
            CardGroup {
                ForEach(current.platforms) { platform in
                    let failure = snapshot?.failures.first { $0.platform == platform }
                    HStack(spacing: 12) {
                        PlatformLogo(platform: platform, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(platform.displayName).font(.system(size: 15, weight: .semibold))
                            Text(failure?.message ?? detail(platform))
                                .font(.system(size: 12))
                                .foregroundStyle(failure == nil ? Palette.ink2 : Palette.warn)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 10)
                }
            }
        }
        .padding(.top, 8)
    }

    private func detail(_ platform: Platform) -> String {
        switch platform {
        case .posthog: current.posthog.map { String(localized: "项目 \($0.projectName) · 时区 \($0.timeZone)") } ?? ""
        case .revenueCat: current.revenueCat.map { String(localized: "项目 \($0.projectName)") } ?? ""
        case .appStore: current.appStore.map { "\($0.appName) · \($0.bundleId)" } ?? ""
        case .googlePlay: current.googlePlay.map { $0.packageName + " · " + String(localized: "保留连接以来的评论") } ?? ""
        }
    }
}

/// A number on the board: its name, the number and what it is set against.
struct NumberTile: View {
    var project: Project
    var metric: Metric
    var snapshot: ProjectSnapshot?
    var compact = false

    var body: some View {
        let reference = metric.reference(in: snapshot)
        let text = metric.text(snapshot?[metric])
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(metric.title(in: project)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink2).lineLimit(1)
                Spacer(minLength: 4)
                if !compact {
                    Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(Palette.ink2)
                }
            }
            Odometer(text: text, size: NumberSize.fit(text, base: compact ? 30 : 40))
                .frame(height: compact ? 32 : 42, alignment: .leading)
            Text(reference?.text ?? (compact ? metric.explanation(in: project) : " "))
                .font(.system(size: 12, weight: reference == nil ? .regular : .semibold))
                .foregroundStyle(reference?.tone.color ?? Palette.ink2)
                .lineLimit(compact ? 2 : 1)
                .minimumScaleFactor(0.85)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: compact ? 104 : 108, alignment: .topLeading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Everyone counted by platform, large: the bar and each platform's count and share.
private struct PlatformCard: View {
    var platforms: [PlatformCount]

    var body: some View {
        let total = max(1, platforms.map(\.count).reduce(0, +))
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("平台占比").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
                Spacer()
                Text("累计").font(.system(size: 12)).foregroundStyle(Palette.ink2)
            }
            SplitBar(platforms: platforms, height: 12, labels: false)
            HStack(alignment: .top, spacing: 16) {
                ForEach(platforms.prefix(4), id: \.name) { part in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle().fill(PlatformStyle.color(part.name)).frame(width: 9, height: 9)
                            Text(PlatformStyle.name(part.name)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                        }
                        Text(Format.number(part.count)).font(Typeface.number(26)).foregroundStyle(Palette.ink)
                        Text(Format.percent(Double(part.count) / Double(total))).font(.system(size: 12)).foregroundStyle(Palette.ink2)
                    }
                }
            }
        }
        .padding(16)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Bars stacked by platform (or any parts), with a readout of the day touched, the last one until then.
struct StackedChart: View {
    struct Bar: Hashable {
        var label: String
        var parts: [String: Int]
        var total: Int { parts.values.reduce(0, +) }
    }

    var title: String
    var note: String
    var bars: [Bar]
    /// Parts in stacking order, bottom first.
    var platforms: [String]
    var names: [String: String] = [:]
    var colors: [String: Color] = [:]
    var money = false
    /// Inside another card: no title, no box of its own.
    var embedded = false
    @State private var selected: String?

    private func name(_ key: String) -> String { names[key] ?? PlatformStyle.name(key) }
    private func color(_ key: String) -> Color { colors[key] ?? PlatformStyle.color(key) }

    /// Every part any bar has, the given order first.
    private var keys: [String] {
        let all = Set(bars.flatMap(\.parts.keys))
        return platforms.filter(all.contains) + all.subtracting(platforms).sorted()
    }

    var body: some View {
        let shown = bars.first { $0.label == selected } ?? bars.last
        VStack(alignment: .leading, spacing: 10) {
            if !embedded {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
                    Text(note).font(.system(size: 12)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let shown {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(money ? Format.money(Double(shown.total)) : Format.number(shown.total)).font(Typeface.number(30)).foregroundStyle(Palette.ink)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(shown.label + (shown == bars.last && !embedded ? " · " + String(localized: "进行中") : "")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                        if keys.count > 1 {
                            HStack(spacing: 8) {
                                ForEach(keys, id: \.self) { key in
                                    HStack(spacing: 4) {
                                        Circle().fill(color(key)).frame(width: 7, height: 7)
                                        Text(verbatim: name(key) + " " + (money ? Format.money(Double(shown.parts[key] ?? 0)) : Format.number(shown.parts[key] ?? 0)))
                                    }
                                }
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        }
                    }
                }
            }
            Chart {
                ForEach(bars, id: \.label) { bar in
                    ForEach(keys, id: \.self) { key in
                        BarMark(x: .value("日", bar.label), y: .value("数", bar.parts[key] ?? 0))
                            .foregroundStyle(by: .value("部分", name(key)))
                            .opacity(selected == nil || selected == bar.label ? 1 : 0.45)
                    }
                }
            }
            .chartForegroundStyleScale(domain: keys.map(name), range: keys.map(color))
            .chartLegend(.hidden)
            .chartXSelection(value: $selected)
            .chartXAxis {
                AxisMarks(values: axisLabels) { value in
                    let label = value.as(String.self)
                    AxisValueLabel(anchor: label == bars.first?.label ? .topLeading : label == bars.last?.label ? .topTrailing : .top)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Palette.line)
                    AxisValueLabel()
                }
            }
            .frame(height: 150)
            .accessibilityLabel(Text(title))
        }
        .padding(embedded ? 0 : 16)
        .background(embedded ? .clear : Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// The first, middle and last day, so labels never crowd.
    private var axisLabels: [String] {
        guard let first = bars.first?.label, let last = bars.last?.label else { return [] }
        return [first, bars[bars.count / 2].label, last]
    }
}
