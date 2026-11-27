import SnuffleKit
import SwiftUI

/// One single number on a project's counting dashboard, to set Snuffle's own beside it.
struct DashboardNumber: Hashable, Sendable {
    /// The chart's name, and the column's when the chart shows several numbers.
    var chart: String
    var value: Double
    var previous: Double?

    /// The dashboard's number that says the same as `value`: the same number, or one within 1% for numbers in the
    /// hundreds and up (the two are read a moment apart). Nil when the dashboard has none.
    static func match(_ value: Double?, in numbers: [DashboardNumber]) -> (number: DashboardNumber, exact: Bool)? {
        guard let value else { return nil }
        if let exact = numbers.first(where: { $0.value == value }) { return (exact, true) }
        guard value >= 100 else { return nil }
        let close = numbers.filter { abs($0.value - value) <= value * 0.01 }.min { abs($0.value - value) < abs($1.value - value) }
        return close.map { ($0, false) }
    }
}

extension Project {
    /// How the people numbers are counted, in a line: "按看板「Launch」算" or Snuffle's own.
    var countingSummary: String {
        if let dashboard = metrics.dashboard { return String(localized: "按看板「\(dashboard.name)」算") }
        if metrics.isStandardPeople {
            return metrics.surfacesLeftOut.isEmpty ? String(localized: "Snuffle 默认：任何事件，按人算") : String(localized: "Snuffle 默认：任何事件，按人算，不含网站访客")
        }
        return String(localized: "自定义口径")
    }
}

/// "数字怎么算" as its own sheet, for a saved project: changes apply when the person taps 保存, and the numbers are
/// read again under them.
struct CountingEditor: View {
    let original: Project
    @State private var draft: Project
    @State private var source: Analytics.CountingSource = .manual
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    init(project: Project) {
        original = project
        _draft = State(initialValue: project)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        RoundIconButton(systemName: "xmark", label: String(localized: "取消")) { dismiss() }
                        Spacer()
                        Button("保存") {
                            model.applyCounting(draft.metrics, to: original, source: source)
                            dismiss()
                        }
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(Palette.paper)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .background(Palette.ink, in: Capsule())
                        .opacity(draft.metrics == original.metrics ? 0.35 : 1)
                        .disabled(draft.metrics == original.metrics)
                        .accessibilityIdentifier("saveCounting")
                    }
                    PageTitle(title: String(localized: "数字怎么算"), subtitle: String(localized: "\(original.name) 的累计、活跃和新增都按这里算。"))
                    CountingOptions(project: $draft, source: $source)
                }
                .padding(16)
            }
            .sheetPage()
        }
    }
}

/// Who counts as a user and how, for a project being edited: read from a PostHog dashboard, or chosen part by part,
/// with what the numbers would be.
struct CountingOptions: View {
    @Binding var project: Project
    @Binding var source: Analytics.CountingSource
    @Environment(AppModel.self) private var model
    @State private var choosingEvent = false
    @State private var addingCondition = false
    @State private var choosingPlatform = false
    @State private var reading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if project.posthog != nil {
                DashboardBanner(project: $project, source: $source, reading: $reading)
                activitySection
                conditionsSection
                unitSection
                otherSection
                CountingPreview(project: project)
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(String(localized: "新增用户"))
                CountingNewUsers(project: $project)
            }
        }
        .sheet(isPresented: $choosingEvent) {
            NavigationStack {
                EventPicker(project: project, purpose: .activity) { metric in
                    if case .event(let name, _) = metric { change { $0.activityEvent = name } }
                }
            }
        }
        .sheet(isPresented: $addingCondition) {
            ConditionSheet(project: project) { condition in change { $0.conditions.append(condition) } }
        }
        .sheet(isPresented: $choosingPlatform) {
            PlatformPropertySheet(current: project.metrics.platformProperty) { property in change { $0.platformProperty = property } }
        }
    }

    /// Changing any part by hand makes the counting the person's own, no longer the dashboard's.
    private func change(_ edit: (inout MetricSettings) -> Void) {
        var next = project.metrics
        edit(&next)
        next.dashboard = nil
        project.metrics = next
        source = .manual
    }

    // MARK: Sections

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(String(localized: "用过一次是指"))
            CardGroup {
                Button { choosingEvent = true } label: {
                    row(
                        title: project.metrics.activityEvent ?? String(localized: "任何事件"),
                        detail: project.metrics.activityEvent == nil ? String(localized: "发过任何事件就算，后台事件也算") : String(localized: "发过这个事件才算，比如打开 App"),
                        mono: project.metrics.activityEvent != nil
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("activityEvent")
                if project.metrics.activityEvent != nil {
                    RowDivider()
                    Button(String(localized: "改回任何事件")) { change { $0.activityEvent = nil } }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.ink2)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
        }
    }

    private var conditionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(String(localized: "只算这些"))
            CardGroup {
                ForEach(Array(project.metrics.conditions.enumerated()), id: \.offset) { index, condition in
                    HStack(spacing: 10) {
                        Text(verbatim: condition)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            change { $0.conditions.remove(at: index) }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(Palette.ink2)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("去掉这个条件")
                    }
                    .padding(.vertical, 4)
                    RowDivider()
                }
                Button { addingCondition = true } label: {
                    Label("加一个条件", systemImage: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("addCondition")
            }
            if project.metrics.dashboard == nil {
                DisclosureGroup {
                    ScopeOptions(project: Binding(get: { project }, set: { next in change { $0.excludedSurfaces = next.metrics.excludedSurfaces } }))
                        .padding(.top, 8)
                } label: {
                    Text(verbatim: project.scopeLine)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink2)
                        .multilineTextAlignment(.leading)
                }
                .tint(Palette.ink)
                .padding(.horizontal, 6)
            }
        }
    }

    private var unitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(String(localized: "一个算"))
            ChoiceBar<PeopleUnit>(
                options: [(value: .person, label: "一个人"), (value: .install, label: "一次安装")],
                selection: Binding(get: { project.metrics.unit }, set: { unit in change { $0.unit = unit } })
            )
            Text(project.metrics.unit == .install
                 ? "按 distinct_id 算：每台设备、每个浏览器各算一个，卸载重装算新的。"
                 : "按 PostHog 的人算：登录后同一个人的几台设备算一个。")
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink2)
                .padding(.horizontal, 6)
        }
    }

    private var otherSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(String(localized: "平台和起始日"))
            CardGroup {
                Button { choosingPlatform = true } label: {
                    row(
                        title: project.metrics.platformProperty ?? String(localized: "PostHog 自带"),
                        detail: project.metrics.platformProperty == nil ? String(localized: "按 SDK 分出 iOS、Android、网页") : String(localized: "按这个事件属性的值分平台"),
                        mono: project.metrics.platformProperty != nil
                    )
                }
                .buttonStyle(.plain)
                RowDivider()
                SinceRow(project: project) { since in change { $0.since = since } }
            }
        }
    }

    private func row(title: String, detail: String, mono: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(mono ? .system(size: 15, weight: .semibold, design: .monospaced) : .system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(verbatim: detail).font(.system(size: 12)).foregroundStyle(Palette.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.forward").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.ink2)
        }
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}

/// The new-user counting options, as they were before the dashboard counting, under their own label.
private struct CountingNewUsers: View {
    @Binding var project: Project

    var body: some View {
        if project.posthog != nil {
            CountingChoices(kind: .newUsers, project: $project)
        } else {
            Text("连上 PostHog 后才能算新增用户。").font(.system(size: 13)).foregroundStyle(Palette.ink2).padding(.horizontal, 6)
        }
    }
}

/// "从 PostHog 看板读口径": lists the project's dashboards, reads the chosen one's charts and takes their counting.
private struct DashboardBanner: View {
    @Binding var project: Project
    @Binding var source: Analytics.CountingSource
    @Binding var reading: Bool
    @Environment(AppModel.self) private var model
    @State private var dashboards: [DashboardSummary]?
    @State private var message: String?
    @State private var needsAccess = false
    @State private var picking = false
    @State private var reconnecting = false
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let dashboard = project.metrics.dashboard {
                HStack(spacing: 8) {
                    Text("按你的看板算")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(accent, in: Capsule())
                    Spacer()
                }
                Text("「\(dashboard.name)」里数人的图都用这套条件，这里照搬过来，算出来的数和看板一样。")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.stripText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(String(localized: "换一个看板")) { Task { await list() } }
                        .buttonStyle(BannerButtonStyle())
                    Button(String(localized: "改回 Snuffle 默认")) {
                        project.metrics = MetricSettings(newUsers: project.metrics.newUsers, revenue: project.metrics.revenue)
                        source = .standard
                    }
                    .buttonStyle(BannerButtonStyle())
                }
            } else {
                Text("从看板读口径")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(Palette.stripText)
                Text("你在 PostHog 里建过看板的话，Snuffle 直接照它的条件算：哪个事件、只算哪些数据、按人还是按安装。数字会和看板一样。")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.stripMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button { Task { await list() } } label: {
                    HStack(spacing: 8) {
                        if reading { ProgressView().controlSize(.small).tint(Palette.onAccent) }
                        Text("选一个看板")
                    }
                }
                .buttonStyle(BannerButtonStyle(filled: true))
                .accessibilityIdentifier("readDashboard")
            }
            if let message {
                Text(message).font(.system(size: 13, weight: .semibold)).foregroundStyle(accent).fixedSize(horizontal: false, vertical: true)
            }
            if needsAccess {
                Button(String(localized: "重新连 PostHog")) { reconnecting = true }
                    .buttonStyle(BannerButtonStyle(filled: true))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.strip, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .sheet(isPresented: $picking) {
            DashboardList(dashboards: dashboards ?? [], current: project.metrics.dashboard?.id) { summary in
                Task { await read(summary) }
            }
        }
        .sheet(isPresented: $reconnecting) {
            // Only the counting is saved from here, so the sign-in does not offer charts it would drop.
            ConnectSourceSheet(platform: .posthog, project: $project, offersDashboards: false)
        }
    }

    private func list() async {
        message = nil
        needsAccess = false
        reading = true
        defer { reading = false }
        do {
            dashboards = try await model.provider.dashboards(for: project)
            if dashboards?.isEmpty == true {
                message = String(localized: "这个 PostHog 项目里还没有看板。")
            } else {
                picking = true
            }
        } catch {
            show(error)
        }
    }

    private func read(_ summary: DashboardSummary) async {
        message = nil
        reading = true
        defer { reading = false }
        do {
            let detail = try await model.provider.dashboard(summary.ref, for: project)
            guard let counting = DashboardReading.counting(detail) else {
                message = String(localized: "「\(summary.name)」里没有数人的图，换一个看板试试。")
                return
            }
            project.metrics = counting.applied(to: project.metrics, timeZone: project.zone)
            source = .dashboard
            message = String(localized: "从 \(counting.sources.count) 张图里读到了口径。")
        } catch {
            show(error)
        }
    }

    /// Accounts connected before dashboards could be read need to sign in again to grant it.
    private func show(_ error: Error) {
        let kind = FailureKind(error)
        if kind == .forbidden || kind == .unauthorized {
            needsAccess = true
            message = String(localized: "读看板需要新的权限，重新连一次 PostHog 就好。")
        } else {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct BannerButtonStyle: ButtonStyle {
    var filled = false
    @Environment(\.accent) private var accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(filled ? Palette.onAccent : Palette.stripText)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(filled ? accent : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(filled ? .clear : Palette.stripMuted))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// The project's dashboards, pinned ones first.
private struct DashboardList: View {
    var dashboards: [DashboardSummary]
    var current: Int?
    var choose: (DashboardSummary) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        PageTitle(title: String(localized: "选一个看板"), subtitle: String(localized: "选平时最常看的那个，Snuffle 会读里面数人的图。"))
                        RoundIconButton(systemName: "xmark", label: String(localized: "关闭")) { dismiss() }
                    }
                    CardGroup {
                        ForEach(Array(dashboards.enumerated()), id: \.element.id) { index, dashboard in
                            if index > 0 { RowDivider() }
                            Button {
                                choose(dashboard)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    if dashboard.pinned { Image(systemName: "pin.fill").font(.system(size: 12)).foregroundStyle(Palette.ink2) }
                                    Text(verbatim: dashboard.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
                                    Spacer()
                                    if dashboard.id == current { Image(systemName: "checkmark").font(.system(size: 14, weight: .heavy)) }
                                }
                                .frame(minHeight: 54)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
            .sheetPage()
        }
    }
}

/// "加一个条件": a HogQL condition, checked against the last day's events before it is used.
private struct ConditionSheet: View {
    var project: Project
    var add: (String) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var result: (kept: Int, total: Int)?
    @State private var error: String?
    @State private var checking = false

    private var condition: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        PageTitle(title: String(localized: "加一个条件"), subtitle: String(localized: "写一条 HogQL 条件，只有符合的事件才算。"))
                        RoundIconButton(systemName: "xmark", label: String(localized: "关闭")) { dismiss() }
                    }
                    TextField(text: $text, prompt: Text(verbatim: "properties.app_environment = 'release'"), axis: .vertical) {
                        Text("条件")
                    }
                    .font(.system(size: 15, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(2...5)
                    .padding(14)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityIdentifier("conditionField")
                    .onChange(of: text) { result = nil; error = nil }
                    if let result {
                        Text("最近一天 \(Format.number(result.total)) 个事件里，符合的有 \(Format.number(result.kept)) 个。")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(result.kept > 0 ? Palette.ink : Palette.bad)
                    }
                    ErrorText(text: error)
                    HStack(spacing: 10) {
                        Button {
                            Task { await check() }
                        } label: {
                            HStack(spacing: 6) {
                                if checking { ProgressView().controlSize(.small) }
                                Text("试一下")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle(filled: false))
                        .disabled(condition.isEmpty || checking)
                        Button("加上") {
                            add(condition)
                            dismiss()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(result == nil)
                    }
                    Text("写法和 PostHog 的 SQL 一样，比如 properties.app_platform IN ('ios', 'android')。先试一下，确认能算出数再加上。")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink2)
                }
                .padding(16)
            }
            .sheetPage()
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        do {
            result = try await model.provider.check(condition: condition, for: project)
            error = nil
        } catch {
            result = nil
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// "平台按": PostHog's own, or an event property the project sends.
private struct PlatformPropertySheet: View {
    var current: String?
    var choose: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        PageTitle(title: String(localized: "平台按什么分"), subtitle: String(localized: "平台占比和各平台的图按这里分。"))
                        RoundIconButton(systemName: "xmark", label: String(localized: "关闭")) { dismiss() }
                    }
                    CardGroup {
                        Button {
                            choose(nil)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("PostHog 自带").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
                                    Text("按 SDK 分出 iOS、Android、网页").font(.system(size: 12)).foregroundStyle(Palette.ink2)
                                }
                                Spacer()
                                if current == nil { Image(systemName: "checkmark").font(.system(size: 14, weight: .heavy)) }
                            }
                            .frame(minHeight: 60)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    SectionLabel(String(localized: "或者按一个事件属性"))
                    TextField(text: $text, prompt: Text(verbatim: "app_platform")) { Text("属性名") }
                        .font(.system(size: 15, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(14)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Button("用这个属性") {
                        choose(text.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(16)
            }
            .sheetPage()
            .onAppear { text = current ?? "" }
        }
    }
}

/// "累计从": all history, or a first day.
private struct SinceRow: View {
    var project: Project
    var set: (Date?) -> Void
    @State private var day = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { project.metrics.since != nil }, set: { on in set(on ? Calendar.current.startOfDay(for: day) : nil) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("累计从某天算起").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text(project.metrics.since == nil ? String(localized: "关着时算全部历史") : String(localized: "之前的人不算进累计，也不算新增"))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink2)
                }
            }
            .toggleStyle(InkToggleStyle())
            .padding(.vertical, 8)
            if let since = project.metrics.since {
                DatePicker(String(localized: "起始日"), selection: Binding(get: { since }, set: { set(startOfDay($0)) }), in: ...Date(), displayedComponents: .date)
                    .environment(\.timeZone, project.zone)
                    .padding(.bottom, 8)
            }
        }
        .onAppear { day = project.metrics.since ?? Date() }
    }

    private func startOfDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = project.zone
        return calendar.startOfDay(for: date)
    }
}

/// What the people numbers would be counted this way, each beside the dashboard's own number when it has one.
private struct CountingPreview: View {
    var project: Project
    @Environment(AppModel.self) private var model
    @State private var values: [Metric: Double] = [:]
    @State private var loading = false
    @State private var numbers: [DashboardNumber] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(String(localized: "按这样算，现在是"))
            CardGroup {
                ForEach(Array(MetricsInUse.board.enumerated()), id: \.offset) { index, metric in
                    if index > 0 { RowDivider() }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: metric.title(in: project)).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                        Spacer()
                        if let match = DashboardNumber.match(values[metric], in: numbers) {
                            Text(match.exact ? "看板 \(Format.number(Int(match.number.value))) ✓" : "看板 ≈ \(Format.number(Int(match.number.value)))")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.up)
                        }
                        if loading && values[metric] == nil {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(verbatim: metric.text(values[metric])).font(Typeface.number(24)).foregroundStyle(Palette.ink)
                        }
                    }
                    .frame(minHeight: 50)
                }
            }
        }
        .task(id: project.metrics) { await measure() }
    }

    private func measure() async {
        loading = true
        values = [:]
        defer { loading = false }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        async let read = try? model.provider.measure(project, metrics: Set(MetricsInUse.board))
        async let dashboard = model.dashboardNumbers(for: project)
        let measured = await read
        guard !Task.isCancelled else { return }
        values = measured ?? [:]
        numbers = await dashboard
    }
}

/// "数字怎么算" pushed from the metric library, for the project being edited there.
struct DefinitionPage: View {
    @Binding var project: Project
    @State private var source = Analytics.CountingSource.manual

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BackButton()
                PageTitle(title: String(localized: "数字怎么算"), subtitle: String(localized: "\(project.name) 的累计、活跃和新增都按这里算。"))
                CountingOptions(project: $project, source: $source)
            }
            .padding(16)
        }
        .sheetPage()
    }
}
