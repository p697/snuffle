import SnuffleKit
import SwiftUI

/// Whether a project's page offers its PostHog dashboards (`AppModel.dashboardOffer`).
enum DashboardOffer: Equatable {
    case none
    /// The project has dashboards to import.
    case dashboards
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

/// The dashboards as chips, one switch for the counting, and the charts as cards to tick. Charts the phone cannot draw
/// are left out rather than explained.
private struct DashboardForm: View {
    @Bindable var picker: DashboardPicker
    var project: Project
    var reconnect: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let dashboards = picker.dashboards, dashboards.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(dashboards) { chip($0) }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
            if picker.counting != nil {
                CardGroup {
                    Toggle("数字按此看板算", isOn: $picker.follow)
                        .toggleStyle(InkToggleStyle())
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("followCounting")
                }
            }
            if let detail = picker.detail {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(detail.tiles.filter(\.canDraw)) { tileCard($0) }
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

    private func chip(_ summary: DashboardSummary) -> some View {
        let selected = picker.selected?.id == summary.id
        return Button {
            Task { await picker.select(summary, project: project, provider: model.provider) }
        } label: {
            Text(verbatim: summary.name)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(selected ? Palette.paper : Palette.ink)
                .padding(.horizontal, 16)
                .frame(minHeight: 40)
                .background(selected ? Palette.ink : Palette.card, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? .clear : Palette.line))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("dashboard-\(summary.id)")
    }

    /// A chart as a card: what kind it is drawn as, its name, and a tick when it is coming along.
    private func tileCard(_ tile: InsightTile) -> some View {
        let picked = picker.chosen.contains { $0.id == tile.id }
        return Button {
            picker.toggle(tile)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: symbol(tile))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(picked ? Palette.ink : Palette.ink2)
                    Spacer()
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(picked ? Palette.ink : Palette.faint)
                }
                Text(verbatim: tile.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
            }
            .padding(14)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(picked ? Palette.ink : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityIdentifier("tile-\(tile.id)")
    }

    private func symbol(_ tile: InsightTile) -> String {
        switch tile.display {
        case "BoldNumber": "number"
        case "ActionsPie", "ActionsBarValue": "chart.pie"
        case "ActionsTable", nil: tile.kind == .table ? "tablecells" : "chart.xyaxis.line"
        case "ActionsLineGraph", "ActionsAreaGraph": "chart.xyaxis.line"
        default: "chart.bar"
        }
    }
}

/// The button under the form: how many charts come along.
private struct ImportButton: View {
    var picker: DashboardPicker
    var action: () -> Void

    var body: some View {
        Button(picker.chosen.isEmpty ? String(localized: "导入") : String(localized: "导入 \(picker.chosen.count) 张图"), action: action)
            .buttonStyle(PrimaryButtonStyle())
            .disabled(picker.choice == nil || (picker.chosen.isEmpty && !(picker.choice?.follow ?? false)))
            .accessibilityIdentifier("importDashboard")
    }
}

// MARK: In the connect flow

/// "导入看板": the step after choosing a PostHog project that has dashboards; "跳过" keeps Snuffle's own counting.
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
                    Button("跳过", action: skip)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("skipDashboard")
                }
                PageTitle(title: String(localized: "导入看板"))
                if let picker {
                    DashboardForm(picker: picker, project: session.project) {}
                }
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) {
            if let picker {
                ImportButton(picker: picker) { use(picker) }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .background(Palette.paper.opacity(0.95))
            }
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

/// "导入看板" for a saved project: from the offer on its page, its menu, the dashboard line under its name, or
/// "管理" above its charts.
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
                    PageTitle(title: String(localized: "导入看板"))
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
