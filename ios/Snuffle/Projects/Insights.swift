import SnuffleKit
import SwiftUI

/// Colours for the series of a dashboard chart: platforms keep theirs, anything else takes the next in a fixed order.
enum SeriesStyle {
    static let palette: [Color] = [
        Palette.ink,
        Color(light: 0x2F6FDB, dark: 0x4F84E8),
        Color(light: 0xD2691E, dark: 0xD06E22),
        Color(light: 0x1E8C6E, dark: 0x22A07B),
        Color(light: 0x7B4BA8, dark: 0x9A6CCB),
        Color(light: 0x8A8A80, dark: 0x6E6E66)
    ]

    static func colors(_ names: [String]) -> [String: Color] {
        var colors: [String: Color] = [:]
        var next = 0
        for name in names {
            if ["ios", "ipados", "android", "web"].contains(name.lowercased()) {
                colors[name] = PlatformStyle.color(name)
            } else {
                colors[name] = palette[next % palette.count]
                next += 1
            }
        }
        return colors
    }
}

/// A chart from the project's PostHog dashboard, drawn from its own query's result.
struct InsightCard: View {
    var project: Project
    var tile: InsightTile
    var result: InsightResult?
    var failure: String?
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: tile.name).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: tile.dashboard.name).font(.system(size: 12)).foregroundStyle(Palette.ink2)
                }
                Spacer()
                Menu {
                    if let url = posthogURL {
                        Button("在 PostHog 打开", systemImage: "safari") { openURL(url) }
                    }
                    if !model.settings.demoMode {
                        Button("从看板拿掉", systemImage: "minus.circle", role: .destructive) {
                            model.pin(project.pins.filter { $0.id != tile.id }, on: project)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Palette.ink2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("更多")
                .padding(.top, -10)
                .padding(.trailing, -10)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var posthogURL: URL? {
        guard let link = project.posthog, let account = model.workspace.account(link.accountId) else { return nil }
        // Accounts are labelled with their region when connected.
        let host = account.subtitle == PostHogOAuth.Region.eu.label ? PostHogOAuth.Region.eu.host : PostHogOAuth.Region.us.host
        return tile.url(host: host, projectId: link.projectId)
    }

    @ViewBuilder
    private var content: some View {
        if !tile.canDraw {
            Text("这种图先不在手机上画，点右上角在 PostHog 里看。").font(.system(size: 13)).foregroundStyle(Palette.ink2)
        } else if let result {
            shape(result.shape(for: tile))
            if let failure {
                Text("这次没读到，显示的是上次的结果：\(failure)").font(.system(size: 12)).foregroundStyle(Palette.bad)
            }
        } else if let failure {
            ErrorText(text: failure)
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 80)
        }
    }

    @ViewBuilder
    private func shape(_ shape: InsightResult.Shape) -> some View {
        switch shape {
        case .numbers(let numbers):
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 12) {
                ForEach(Array(numbers.enumerated()), id: \.offset) { _, number in
                    VStack(alignment: .leading, spacing: 2) {
                        if numbers.count > 1 {
                            Text(verbatim: number.name).font(.system(size: 12)).foregroundStyle(Palette.ink2).lineLimit(1)
                        }
                        Text(Self.format(number.value)).font(Typeface.number(numbers.count > 1 ? 28 : 40)).foregroundStyle(Palette.ink)
                        if let previous = number.previous, let change = Metric.change(number.value, from: previous) {
                            Text(change.text).font(.system(size: 12, weight: .semibold)).foregroundStyle(change.tone.color)
                        }
                    }
                }
            }
        case .split(let parts):
            let names = parts.map(\.name)
            let colors = SeriesStyle.colors(names)
            let total = max(1, parts.map(\.value).reduce(0, +))
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        ForEach(parts.prefix(6), id: \.name) { part in
                            Capsule().fill(colors[part.name] ?? Palette.faint)
                                .frame(width: max(3, (geometry.size.width - CGFloat(min(parts.count, 6) - 1) * 2) * part.value / total))
                        }
                    }
                }
                .frame(height: 10)
                ForEach(parts.prefix(6), id: \.name) { part in
                    HStack(spacing: 6) {
                        Circle().fill(colors[part.name] ?? Palette.faint).frame(width: 8, height: 8)
                        Text(verbatim: PlatformStyle.name(part.name)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                        Spacer()
                        Text(Self.format(part.value)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                        Text(Format.percent(part.value / total)).font(.system(size: 12)).foregroundStyle(Palette.ink2).frame(minWidth: 44, alignment: .trailing)
                    }
                }
            }
        case .bars(let labels, let series):
            let names = series.map(\.name)
            StackedChart(
                title: tile.name,
                note: "",
                bars: labels.enumerated().map { index, label in
                    StackedChart.Bar(label: Self.shortLabel(label), parts: Dictionary(series.map { ($0.name, Int(($0.values[safe: index] ?? 0).rounded())) }, uniquingKeysWith: +))
                },
                platforms: names,
                names: Dictionary(names.map { ($0, PlatformStyle.name($0)) }, uniquingKeysWith: { first, _ in first }),
                colors: SeriesStyle.colors(names),
                embedded: true
            )
        case .table(let columns, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        ForEach(columns, id: \.self) { column in
                            Text(verbatim: column).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink2)
                        }
                    }
                    Divider()
                    ForEach(Array(rows.prefix(10).enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(verbatim: cell).font(.system(size: 13)).foregroundStyle(Palette.ink).lineLimit(1)
                            }
                        }
                    }
                }
            }
            if rows.count > 10 {
                Text("还有 \(rows.count - 10) 行，在 PostHog 里看全部").font(.system(size: 12)).foregroundStyle(Palette.ink2)
            }
        case .empty:
            Text("这张图现在没有数据").font(.system(size: 13)).foregroundStyle(Palette.ink2)
        }
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? Format.number(Int(value)) : String(format: "%.2f", value)
    }

    /// "2026-11-26" reads as "11/26"; other labels stay as they are.
    static func shortLabel(_ label: String) -> String {
        let parts = label.prefix(10).split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else { return label }
        var components = DateComponents()
        components.year = Int(parts[0])
        components.month = month
        components.day = day
        guard let date = Calendar(identifier: .gregorian).date(from: components) else { return label }
        return Format.day(date, in: Calendar(identifier: .gregorian).timeZone)
    }
}

/// "从看板添加": the project's dashboards and their charts, to place on its board.
struct ChartPicker: View {
    var project: Project
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var dashboards: [DashboardSummary] = []
    @State private var dashboard: DashboardSummary?
    @State private var detail: DashboardDetail?
    @State private var chosen: [InsightTile] = []
    @State private var loading = false
    @State private var error: String?
    @State private var needsAccess = false
    @State private var reconnecting = false
    @State private var draft: Project

    init(project: Project) {
        self.project = project
        _draft = State(initialValue: project)
        _chosen = State(initialValue: project.pins)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        RoundIconButton(systemName: "xmark", label: String(localized: "取消")) { dismiss() }
                        Spacer()
                        Button("完成") {
                            model.pin(chosen, on: project)
                            dismiss()
                        }
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(Palette.paper)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .background(Palette.ink, in: Capsule())
                        .accessibilityIdentifier("savePins")
                    }
                    PageTitle(title: String(localized: "从看板添加"), subtitle: String(localized: "挑中的图在手机上原样跑你写的查询，刷新时一起更新。"))
                    if dashboards.count > 1 {
                        Picker(String(localized: "看板"), selection: Binding(get: { dashboard?.id ?? 0 }, set: { id in
                            dashboard = dashboards.first { $0.id == id }
                            Task { await loadDetail() }
                        })) {
                            ForEach(dashboards) { item in Text(verbatim: item.name).tag(item.id) }
                        }
                        .pickerStyle(.menu)
                        .tint(Palette.ink)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    if loading { ProgressView().frame(maxWidth: .infinity, minHeight: 100) }
                    ErrorText(text: error)
                    if needsAccess {
                        Button(String(localized: "重新连 PostHog")) { reconnecting = true }.buttonStyle(PrimaryButtonStyle())
                    }
                    if let detail {
                        CardGroup {
                            ForEach(Array(detail.tiles.enumerated()), id: \.element.id) { index, tile in
                                if index > 0 { RowDivider() }
                                tileRow(tile)
                            }
                        }
                        Text("漏斗、留存、路径这几种图先不在手机上画，可以在 PostHog 里看。")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink2)
                            .padding(.horizontal, 6)
                    }
                }
                .padding(16)
            }
            .sheetPage()
            .task { await loadDashboards() }
            .sheet(isPresented: $reconnecting, onDismiss: { Task { await loadDashboards() } }) {
                ConnectSourceSheet(platform: .posthog, project: $draft)
            }
        }
    }

    private func tileRow(_ tile: InsightTile) -> some View {
        let picked = chosen.contains { $0.id == tile.id }
        return Button {
            if picked { chosen.removeAll { $0.id == tile.id } } else { chosen.append(tile) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(tile.canDraw ? Palette.ink : Palette.faint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: tile.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(tile.canDraw ? Palette.ink : Palette.ink2).fixedSize(horizontal: false, vertical: true)
                    Text(kind(tile)).font(.system(size: 12)).foregroundStyle(Palette.ink2)
                }
                Spacer()
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!tile.canDraw)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private func kind(_ tile: InsightTile) -> String {
        guard tile.canDraw else { return String(localized: "先不支持") }
        switch tile.display {
        case "BoldNumber": return String(localized: "数字")
        case "ActionsPie", "ActionsBarValue": return String(localized: "占比")
        case "ActionsTable", nil: return tile.kind == .table ? String(localized: "表格") : String(localized: "折线")
        default: return String(localized: "柱状图")
        }
    }

    private func loadDashboards() async {
        loading = true
        error = nil
        needsAccess = false
        defer { loading = false }
        do {
            dashboards = try await model.provider.dashboards(for: draft)
            dashboard = dashboards.first { $0.id == project.metrics.dashboard?.id } ?? dashboards.first { $0.id == project.pins.first?.dashboard.id } ?? dashboards.first
            if dashboards.isEmpty { error = String(localized: "这个 PostHog 项目里还没有看板。") }
            await loadDetail()
        } catch {
            show(error)
        }
    }

    private func loadDetail() async {
        guard let dashboard else { return }
        loading = true
        defer { loading = false }
        do {
            detail = try await model.provider.dashboard(dashboard.ref, for: draft)
        } catch {
            show(error)
        }
    }

    private func show(_ error: Error) {
        let kind = FailureKind(error)
        needsAccess = kind == .forbidden || kind == .unauthorized
        self.error = needsAccess ? String(localized: "读看板需要新的权限，重新连一次 PostHog 就好。") : (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
