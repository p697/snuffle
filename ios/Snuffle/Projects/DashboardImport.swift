import SnuffleKit
import SwiftUI

/// Whether a project's page offers its PostHog dashboards (`AppModel.dashboardOffer`).
enum DashboardOffer: Equatable {
    case none
    /// How many there are, and the first one's name for an example.
    case dashboards(Int, first: String)
    /// The account was connected before Snuffle read dashboards: signing in again allows it.
    case needsAccess
}

/// What importing a dashboard does to a project: its charts go on the board, and its counting is followed when chosen.
struct DashboardChoice {
    var dashboard: DashboardRef
    var counting: DashboardReading.Counting?
    var follow: Bool
    var pins: [InsightTile]

    func apply(to project: inout Project) {
        project.pins = pins
        project.dashboardChecked = true
        if follow, let counting {
            project.metrics = counting.applied(to: project.metrics, timeZone: project.zone)
        } else if project.metrics.dashboard?.id == dashboard.id {
            project.metrics.countStandard()
        }
    }

    /// "先不用": no charts, and Snuffle's own counting even where the dashboard's was taken when the project linked.
    static func skip(_ project: inout Project) {
        project.pins = []
        project.dashboardChecked = true
        if project.metrics.dashboard != nil { project.metrics.countStandard() }
    }
}

extension MetricSettings {
    /// Snuffle's own way to count people, keeping how new users and revenue are counted.
    mutating func countStandard() {
        self = MetricSettings(newUsers: newUsers, revenue: revenue)
    }
}

/// The dashboards of a project, the one chosen, its charts and whether to count the way it does, for both the step
/// in the connect flow and the sheet on a project's page.
@MainActor
@Observable
final class DashboardPicker {
    /// Charts suggested from a dashboard before the person picks any.
    static let suggested = 6

    private(set) var dashboards: [DashboardSummary]?
    private(set) var selected: DashboardSummary?
    private(set) var details: [Int: DashboardDetail] = [:]
    private(set) var chosen: [InsightTile]
    var follow = true
    private(set) var loading = false
    private(set) var error: String?
    private(set) var needsAccess = false
    /// The dashboard the project counts like now.
    let followed: Int?
    /// Counting the person set up by hand is not swapped for a dashboard's unless they turn it on.
    private let countsByHand: Bool
    /// Charts picked by hand stay picked when another dashboard is shown.
    private var touched: Bool

    init(project: Project) {
        chosen = project.pins
        followed = project.metrics.dashboard?.id
        countsByHand = project.metrics.dashboard == nil && !project.metrics.isStandardPeople
        touched = !project.pins.isEmpty
    }

    var detail: DashboardDetail? { selected.flatMap { details[$0.id] } }
    var counting: DashboardReading.Counting? { detail.flatMap(DashboardReading.counting) }

    var choice: DashboardChoice? {
        selected.map { DashboardChoice(dashboard: $0.ref, counting: counting, follow: follow && counting != nil, pins: chosen) }
    }

    /// `known`: the list already read when the project was linked.
    func load(_ project: Project, provider: any DataProvider, known: [DashboardSummary]? = nil) async {
        loading = true
        error = nil
        needsAccess = false
        defer { loading = false }
        do {
            let list: [DashboardSummary]
            if let known { list = known } else { list = try await provider.dashboards(for: project) }
            dashboards = list
            selected = list.first { $0.id == followed } ?? list.first { $0.id == chosen.first?.dashboard.id } ?? list.first
            await loadDetail(project, provider: provider)
        } catch {
            show(error)
        }
    }

    func select(_ summary: DashboardSummary, project: Project, provider: any DataProvider) async {
        selected = summary
        await loadDetail(project, provider: provider)
    }

    func toggle(_ tile: InsightTile) {
        touched = true
        if chosen.contains(where: { $0.id == tile.id }) {
            chosen.removeAll { $0.id == tile.id }
        } else {
            chosen.append(tile)
        }
    }

    private func loadDetail(_ project: Project, provider: any DataProvider) async {
        guard let summary = selected else { return }
        if details[summary.id] == nil {
            loading = true
            defer { loading = false }
            do {
                details[summary.id] = try await provider.dashboard(summary.ref, for: project)
            } catch {
                show(error)
                return
            }
        }
        guard selected?.id == summary.id, let detail = details[summary.id] else { return }
        follow = DashboardReading.counting(detail) != nil && (!countsByHand || summary.id == followed)
        if !touched { chosen = Array(detail.tiles.filter(\.canDraw).prefix(Self.suggested)) }
    }

    private func show(_ error: Error) {
        let kind = FailureKind(error)
        needsAccess = kind == .forbidden || kind == .unauthorized
        self.error = needsAccess ? String(localized: "读看板需要新的权限，重新连一次 PostHog 就好。") : describe(error)
    }
}

/// The dashboards to choose from, the counting the chosen one would bring, and its charts to tick.
private struct DashboardForm: View {
    @Bindable var picker: DashboardPicker
    var project: Project
    var reconnect: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let dashboards = picker.dashboards, dashboards.count > 1 {
                SectionLabel(String(localized: "选你平时看的那个"))
                CardGroup {
                    ForEach(Array(dashboards.enumerated()), id: \.element.id) { index, summary in
                        if index > 0 { RowDivider() }
                        dashboardRow(summary)
                    }
                }
            } else if let only = picker.selected {
                SectionLabel(String(localized: "看板"))
                CardGroup { dashboardRow(only) }
            }
            if picker.detail != nil { countingStrip }
            if let detail = picker.detail {
                SectionLabel(String(localized: "图表 · 已选 \(picker.chosen.count) 张"))
                CardGroup {
                    ForEach(Array(detail.tiles.enumerated()), id: \.element.id) { index, tile in
                        if index > 0 { RowDivider() }
                        tileRow(tile)
                    }
                }
                if detail.tiles.contains(where: { !$0.canDraw }) {
                    Text("漏斗、留存、路径这几种图先不在手机上画，可以在 PostHog 里看。")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink2)
                        .padding(.horizontal, 6)
                }
            }
            if picker.loading { ProgressView().frame(maxWidth: .infinity, minHeight: 80) }
            ErrorText(text: picker.error)
            if picker.needsAccess {
                Button(String(localized: "重新连 PostHog"), action: reconnect).buttonStyle(PrimaryButtonStyle())
            }
            if picker.dashboards?.isEmpty == true {
                Text("这个 PostHog 项目里还没有看板。")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.ink2)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func dashboardRow(_ summary: DashboardSummary) -> some View {
        let selected = picker.selected?.id == summary.id
        return Button {
            Task { await picker.select(summary, project: project, provider: model.provider) }
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .strokeBorder(selected ? Palette.ink : Palette.faint, lineWidth: selected ? 7 : 2)
                    .frame(width: 22, height: 22)
                Text(verbatim: summary.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if summary.id == picker.followed {
                    Text("现在按它算").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.ink2)
                }
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("dashboard-\(summary.id)")
    }

    /// Whether the numbers follow this dashboard, and what it counts, in the dark strip used for counting.
    @ViewBuilder
    private var countingStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let counting = picker.counting {
                Toggle(isOn: $picker.follow) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("数字也按这个看板算")
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundStyle(Palette.stripText)
                        Text(String(localized: "累计、活跃和新增都照 \(Self.names(counting.sources)) 的条件算，和看板一样。"))
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.stripMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(InkToggleStyle(onStrip: true))
                .accessibilityIdentifier("followCounting")
                FlowLayout(spacing: 6) {
                    ForEach(tags(counting), id: \.self) { tag in
                        Text(verbatim: tag)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.stripText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Palette.stripText.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            } else {
                Text("这个看板里没有数人的图，数字仍按 Snuffle 默认算。")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.stripText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.strip, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// The charts the counting was read from, quoted: up to three, then how many more.
    static func names(_ sources: [String]) -> String {
        let quoted = sources.prefix(3).map { String(localized: "「\($0)」") }
        let shown = ListFormatter.localizedString(byJoining: quoted)
        return sources.count > 3 ? String(localized: "\(shown) 等 \(sources.count) 张图") : shown
    }

    /// The counting in a few words: the event, the conditions, people or installs, the platform property.
    private func tags(_ counting: DashboardReading.Counting) -> [String] {
        var tags = [counting.activityEvent.map { String(localized: "事件 \($0)") } ?? String(localized: "任何事件")]
        if !counting.conditions.isEmpty { tags.append(String(localized: "\(counting.conditions.count) 个条件")) }
        tags.append(counting.unit == .install ? String(localized: "按安装算") : String(localized: "按人算"))
        if let property = counting.platformProperty { tags.append(String(localized: "按 \(property) 分平台")) }
        return tags
    }

    private func tileRow(_ tile: InsightTile) -> some View {
        let picked = picker.chosen.contains { $0.id == tile.id }
        return Button {
            picker.toggle(tile)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: !tile.canDraw ? "circle.dashed" : picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(tile.canDraw ? Palette.ink : Palette.faint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: tile.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tile.canDraw ? Palette.ink : Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
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
        .accessibilityIdentifier("tile-\(tile.id)")
    }

    private func kind(_ tile: InsightTile) -> String {
        guard tile.canDraw else { return String(localized: "手机上先不支持") }
        switch tile.display {
        case "BoldNumber": return String(localized: "数字")
        case "ActionsPie", "ActionsBarValue": return String(localized: "占比")
        case "ActionsTable", nil: return tile.kind == .table ? String(localized: "表格") : String(localized: "折线")
        default: return String(localized: "柱状图")
        }
    }
}

/// The button under the form: what importing brings, or why it cannot yet.
private struct ImportButton: View {
    var picker: DashboardPicker
    var action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(PrimaryButtonStyle())
            .disabled(picker.choice == nil || (picker.chosen.isEmpty && !(picker.choice?.follow ?? false)))
            .accessibilityIdentifier("importDashboard")
    }

    private var title: String {
        let charts = picker.chosen.count
        let follows = picker.choice?.follow ?? false
        if charts == 0 { return String(localized: "只按看板算数字") }
        return follows ? String(localized: "导入看板和 \(charts) 张图") : String(localized: "导入 \(charts) 张图")
    }
}

// MARK: In the connect flow

/// "把你的 PostHog 看板带过来": the step after choosing a PostHog project that has dashboards.
struct ImportBoardPage: View {
    @Environment(ConnectSession.self) private var session
    @Environment(AppModel.self) private var model
    var next: () -> Void
    @State private var picker: DashboardPicker?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    BackButton()
                    Spacer()
                    if let name = session.project.posthog?.projectName {
                        SuccessBadge(text: String(localized: "已选 \(name)"))
                    }
                }
                PageTitle(title: String(localized: "把你的 PostHog 看板带过来"), subtitle: String(localized: "数字照看板的口径算，图表原样搬到手机上，每次刷新一起更新。"))
                if let picker {
                    DashboardForm(picker: picker, project: session.project) {}
                }
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 2) {
                if let picker { ImportButton(picker: picker, action: { use(picker) }) }
                Button("先不用，按 Snuffle 默认算", action: skip)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("skipDashboard")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .background(Palette.paper.opacity(0.95))
        }
        .sheetPage()
        .task {
            guard picker == nil else { return }
            let picker = DashboardPicker(project: session.project)
            self.picker = picker
            await picker.load(session.project, provider: model.provider, known: session.postHogDashboards)
        }
    }

    private func use(_ picker: DashboardPicker) {
        guard let choice = picker.choice else { return }
        choice.apply(to: &session.project)
        Analytics.dashboardImportResolved(.connect, imported: true, charts: choice.pins.count, followsCounting: session.project.metrics.dashboard != nil)
        next()
    }

    private func skip() {
        DashboardChoice.skip(&session.project)
        Analytics.dashboardImportResolved(.connect, imported: false, charts: 0, followsCounting: false)
        next()
    }
}

// MARK: On a project's page

/// "从看板导入", for a saved project: from the offer on its page, its menu, or "管理" above its charts.
struct DashboardImportSheet: View {
    var project: Project
    var entry: Analytics.DashboardImportEntry
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var picker: DashboardPicker
    @State private var reconnecting = false
    @State private var imported = false

    init(project: Project, entry: Analytics.DashboardImportEntry) {
        self.project = project
        self.entry = entry
        _picker = State(initialValue: DashboardPicker(project: project))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        RoundIconButton(systemName: "xmark", label: String(localized: "取消")) { dismiss() }
                        Spacer()
                    }
                    PageTitle(title: String(localized: "从看板导入"), subtitle: String(localized: "数字照看板的口径算，图表原样搬到手机上，每次刷新一起更新。"))
                    DashboardForm(picker: picker, project: project) { reconnecting = true }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom) {
                ImportButton(picker: picker) {
                    guard let choice = picker.choice else { return }
                    imported = true
                    model.importDashboard(choice, into: project, entry: entry)
                    dismiss()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .background(Palette.paper.opacity(0.95))
            }
            .sheetPage()
            .task { await picker.load(project, provider: model.provider) }
            // Closed without importing, by the button or a swipe.
            .onDisappear {
                if !imported { Analytics.dashboardImportResolved(entry, imported: false, charts: project.pins.count, followsCounting: project.metrics.dashboard != nil) }
            }
            .sheet(isPresented: $reconnecting, onDismiss: { Task { await picker.load(current, provider: model.provider) } }) {
                ReconnectSheet(project: current, platform: .posthog, offersDashboards: false)
            }
        }
    }

    /// The saved project, which signing in again may have changed.
    private var current: Project { model.projects.first { $0.id == project.id } ?? project }
}
