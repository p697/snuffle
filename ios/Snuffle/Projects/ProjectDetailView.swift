import Charts
import SnuffleKit
import SwiftUI

/// One project's board, the phone version of its PostHog dashboard: how it counts (or the offer to count like its own
/// dashboard), the four people numbers (tap one for how it is counted), the charts brought over from its dashboard, the
/// platform split, a chart per number by platform, everything else it reads, and its sources with the missing ones a
/// tap away. Everything to change sits in one menu.
struct ProjectDetailView: View {
    var project: Project
    @Environment(AppModel.self) private var model
    @Environment(RootSheets.self) private var sheets
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    /// The range picked; until then 30 days with Pro, 7 without.
    @State private var picked: Int?
    @State private var loading = false
    @State private var boardError: String?
    @State private var pinFailures: [Int: String] = [:]
    @State private var editing = false
    @State private var editingCard = false
    @State private var editingCounting = false
    @State private var importing: Analytics.DashboardImportEntry?
    @State private var connecting: Platform?
    @State private var sheetMetric: Metric?
    @State private var offer = DashboardOffer.none

    /// The saved project, which the editors change after this page opened.
    private var current: Project { model.projects.first { $0.id == project.id } ?? project }
    private var snapshot: ProjectSnapshot? { model.snapshot(project.id) }
    private var board: ProjectBoard? { model.boards[project.id]?[days] }
    private var canSeeMonth: Bool { model.pro.isPro || model.settings.demoMode }
    private var days: Int { picked ?? (canSeeMonth ? 30 : 7) }
    /// One source or none: what is missing matters more than the charts, so the sources come right after the numbers.
    private var thin: Bool { current.platforms.count <= 1 }
    private var demo: Bool { model.settings.demoMode }
    /// Something was brought over from a PostHog dashboard: its counting or its charts.
    private var imported: Bool { current.metrics.dashboard != nil || !current.pins.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if current.posthog != nil { counting }
                heroes
                if thin { sources }
                if let platforms = snapshot?.platforms, !platforms.isEmpty {
                    PlatformCard(platforms: platforms)
                }
                if current.posthog != nil, !current.pins.isEmpty { pins }
                if current.posthog != nil {
                    rangePicker
                    charts
                }
                others
                if !thin { sources }
            }
            .padding(16)
        }
        .clearsTabBar()
        .background(Palette.paper)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !demo { menu }
        }
        .refreshable {
            await model.refresh([current], trigger: .project)
        }
        .sheet(isPresented: $editing) { ProjectEditor(project: current) }
        .sheet(isPresented: $editingCard) { CardEditor(project: current) }
        .sheet(isPresented: $editingCounting) { CountingEditor(project: current) }
        .sheet(item: $importing) { entry in DashboardImportSheet(project: current, entry: entry) }
        .sheet(item: $connecting) { platform in ReconnectSheet(project: current, platform: platform) }
        .sheet(item: $sheetMetric) { metric in MetricSheet(project: current, metric: metric) }
        // Deleted from the editor: leave the page instead of showing an empty one.
        .onChange(of: model.workspace.projects.contains { $0.id == project.id }) { _, exists in
            if !exists { dismiss() }
        }
        .task(id: BoardKey(days: days, refreshed: model.lastRefresh, counting: current.metrics)) { await loadBoard() }
        .task(id: PinsKey(refreshed: model.lastRefresh, pins: current.pins.map(\.id))) { await runPins() }
        .task(id: OfferKey(link: current.posthog, counting: current.metrics.dashboard, pins: current.pins.count, dismissed: model.dismissedDashboardOffers.contains(project.id))) {
            offer = demo ? .none : await model.dashboardOffer(for: current)
        }
    }

    private struct BoardKey: Equatable { var days: Int; var refreshed: Date?; var counting: MetricSettings }
    private struct PinsKey: Equatable { var refreshed: Date?; var pins: [Int] }
    private struct OfferKey: Equatable { var link: PostHogLink?; var counting: DashboardRef?; var pins: Int; var dismissed: Bool }

    /// The one place to change the project: its card, its counting, its dashboard, its settings.
    private var menu: some View {
        Menu {
            Button("调整总览里的卡片", systemImage: "slider.horizontal.3") { editingCard = true }
                .accessibilityIdentifier("editCard")
            if current.posthog != nil {
                Button("数字怎么算", systemImage: "chart.bar.xaxis") { editingCounting = true }
                    .accessibilityIdentifier("editCounting")
                Button(imported ? "管理看板" : "从看板导入", systemImage: "square.grid.2x2") { importing = .menu }
                    .accessibilityIdentifier("menuImportDashboard")
            }
            Divider()
            Button("项目设置", systemImage: "gearshape") { editing = true }
                .accessibilityIdentifier("projectSettings")
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("更多")
        .accessibilityIdentifier("projectMenu")
    }

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

    /// "刚刚更新 · 按 UTC 计日".
    private var statusLine: String {
        var parts = [snapshot.map { String(localized: "更新于 \(Format.ago($0.fetchedAt))") } ?? String(localized: "还没刷新过")]
        if let zone = current.dayZoneLabel { parts.append(String(localized: "按 \(zone) 计日")) }
        return parts.joined(separator: " · ")
    }

    /// How the people numbers are counted, always in sight under the name: the dashboard followed, or the offer to
    /// follow one the project has, or Snuffle's own counting. Each opens what changes it.
    @ViewBuilder
    private var counting: some View {
        if let dashboard = current.metrics.dashboard {
            countingChip(tag: String(localized: "按看板算"), text: String(localized: "「\(dashboard.name)」· 和网页一致"), strong: true) { importing = .counting }
        } else if !demo, case .dashboards(let count, let first) = offer {
            OfferBanner(
                title: String(localized: "你在 PostHog 有 \(count) 个看板"),
                message: String(localized: "现在的数按 Snuffle 默认口径算，可能和你平时看的不一样。导入后，数字照看板算，图表也一起搬过来。"),
                action: String(localized: "导入看板"),
                example: String(localized: "比如「\(first)」"),
                run: { importing = .offer },
                close: {
                    model.dismissDashboardOffer(for: current)
                    Analytics.dashboardImportResolved(.offer, imported: false, charts: 0, followsCounting: false)
                }
            )
        } else if !demo, offer == .needsAccess {
            OfferBanner(
                title: String(localized: "要导入你的 PostHog 看板？"),
                message: String(localized: "这个账号连上时，Snuffle 还不读看板。重新连一次 PostHog，就能把看板的口径和图表带过来。"),
                action: String(localized: "重新连 PostHog"),
                example: nil,
                run: { connecting = .posthog },
                close: { model.dismissDashboardOffer(for: current) }
            )
        } else {
            countingChip(tag: nil, text: current.countingSummary, strong: false) { editingCounting = true }
        }
    }

    /// The dashboard followed opens the dashboard sheet (switch it, stop following, its charts); Snuffle's own
    /// counting opens the counting editor.
    private func countingChip(tag: String?, text: String, strong: Bool, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 10) {
                if let tag {
                    Text(tag)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(accent, in: Capsule())
                }
                Text(verbatim: text)
                    .font(.system(size: 14, weight: strong ? .bold : .medium))
                    .foregroundStyle(strong ? Palette.ink : Palette.ink2)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.forward").font(.system(size: 12, weight: .bold)).foregroundStyle(strong ? Palette.ink : Palette.faint)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(strong ? Palette.ink : Palette.line, lineWidth: strong ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(demo)
        .accessibilityHint("看数字怎么算")
        .accessibilityIdentifier("countingChip")
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

    /// "走势": Snuffle's own charts, apart from the dashboard's, with the range they cover beside the heading.
    private var rangePicker: some View {
        HStack(spacing: 12) {
            Text("走势").font(.system(size: 18, weight: .heavy)).foregroundStyle(Palette.ink)
            Spacer(minLength: 8)
            Picker("范围", selection: Binding(get: { days }, set: select)) {
                Text("7 天").tag(7)
                Text(canSeeMonth ? "30 天" : "30 天 · Pro").tag(30)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .padding(.top, current.pins.isEmpty ? 0 : 8)
        .padding(.leading, 4)
    }

    private func select(_ next: Int) {
        if next == 30 && !canSeeMonth {
            sheets.openPaywall(.history)
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

    /// The charts brought over from its PostHog dashboards, right under the numbers: they are the person's own view.
    private var pins: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("来自你的看板").font(.system(size: 18, weight: .heavy)).foregroundStyle(Palette.ink)
                    Text(verbatim: ListFormatter.localizedString(byJoining: Array(Set(current.pins.map(\.dashboard.name))).sorted()))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink2)
                }
                Spacer()
                if !demo {
                    Button(String(localized: "管理")) { importing = .charts }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Palette.ink)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("pickCharts")
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 4)
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

    /// Where the numbers come from, and the sources still missing with what each would add, connected right here.
    private var sources: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(thin && !demo ? String(localized: "数据来源 · 接上更多，数更全") : String(localized: "数据来源"))
            SourceRows(project: current, status: status, connect: demo ? nil : { connecting = $0 })
        }
        .padding(.top, thin ? 0 : 8)
    }

    private func status(_ platform: Platform) -> (text: String, warn: Bool)? {
        if let failure = snapshot?.failures.first(where: { $0.platform == platform }) { return (failure.message, true) }
        return (detail(platform), false)
    }

    private func detail(_ platform: Platform) -> String {
        switch platform {
        case .posthog: current.posthog.map { String(localized: "项目 \($0.projectName) · 时区 \($0.timeZone)") } ?? ""
        case .revenueCat: current.revenueCat.map { String(localized: "项目 \($0.projectName)") } ?? ""
        case .appStore: current.appStore.map { [$0.appName, $0.hasKey ? nil : String(localized: "不用密钥，只看评分和评论")].compactMap { $0 }.joined(separator: " · ") } ?? ""
        case .googlePlay: current.googlePlay.map { $0.packageName + " · " + String(localized: "保留连接以来的评论") } ?? ""
        }
    }
}

extension Analytics.DashboardImportEntry: Identifiable {
    var id: String { rawValue }
}

/// A dark note at the top of a project's page offering one step that changes its numbers, which can be closed for good.
private struct OfferBanner: View {
    var title: String
    var message: String
    var action: String
    var example: String?
    var run: () -> Void
    var close: () -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 17, weight: .heavy)).foregroundStyle(Palette.stripText)
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.stripMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.stripMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, -12)
                .padding(.trailing, -12)
                .accessibilityLabel("不再提示")
            }
            HStack(spacing: 10) {
                Button(action: run) {
                    Text(action)
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 40)
                        .background(accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("offerAction")
                if let example {
                    Text(verbatim: example)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.stripMuted)
                        .lineLimit(1)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.strip, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboardOffer")
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
                        Text(Format.number(part.count)).font(Typeface.number(26)).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.5)
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
    @State private var plotWidth: CGFloat = 300

    private func name(_ key: String) -> String { names[key] ?? PlatformStyle.name(key) }
    private func color(_ key: String) -> Color { colors[key] ?? PlatformStyle.color(key) }

    /// Every part any bar has, the given order first.
    private var keys: [String] {
        let all = Set(bars.flatMap(\.parts.keys))
        return platforms.filter(all.contains) + all.subtracting(platforms).sorted()
    }

    var body: some View {
        let shown = bars.first { $0.label == selected } ?? bars.last
        let placed = Self.axisLabels(bars.map(\.label), plotWidth: plotWidth, labelWidth: labelWidth)
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
                // Charts on iOS 27 labels every category whatever `values` asks for, so the choice is made per mark.
                AxisMarks(values: bars.map(\.label)) { value in
                    if let label = value.as(String.self), let anchor = placed[label] {
                        AxisValueLabel(anchor: anchor)
                    }
                }
            }
            .chartPlotStyle { plot in
                plot.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { plotWidth = $0 }
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

    /// The longest label's width in the axis font.
    private var labelWidth: CGFloat {
        let longest = bars.max { $0.label.count < $1.label.count }?.label ?? ""
        return ceil((longest as NSString).size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .caption2)]).width)
    }

    /// The labels under the axis and where each sits on its bar; bars left out get none. Every bar is labeled while
    /// each has room; otherwise every few bars, counted back from the latest, so labels stay well apart however dense
    /// the bars are. A label that would run past the plot's edge is aligned to that edge.
    static func axisLabels(_ labels: [String], plotWidth: CGFloat, labelWidth: CGFloat) -> [String: UnitPoint] {
        guard !labels.isEmpty, plotWidth > 0 else { return [:] }
        let slot = plotWidth / CGFloat(labels.count)
        // Room for two labels pushed toward each other by the edges, and a gap.
        let spacing = slot >= labelWidth + 12 ? slot : max(64, labelWidth * 2 + 12)
        let step = max(1, Int((spacing / slot).rounded(.up)))
        var placed: [String: UnitPoint] = [:]
        for index in stride(from: labels.count - 1, through: 0, by: -step) {
            let center = (CGFloat(index) + 0.5) * slot
            placed[labels[index]] = center < labelWidth / 2 ? .topLeading : center > plotWidth - labelWidth / 2 ? .topTrailing : .top
        }
        return placed
    }
}
