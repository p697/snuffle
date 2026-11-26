import SnuffleKit
import SwiftUI

/// What one number is and how it is counted: in a sentence, part by part, set beside the dashboard's own number, and
/// as the HogQL Snuffle runs. Opened by tapping a number on a project's board.
struct MetricSheet: View {
    var project: Project
    var metric: Metric
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var numbers: [DashboardNumber]?
    @State private var showingSQL = false
    @State private var editingCounting = false

    private var snapshot: ProjectSnapshot? { model.snapshot(project.id) }
    private var settings: MetricSettings { project.metrics }
    private var isPeople: Bool { metric.isScoped || metric == .newUsers || metric == .newWeek }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: project.name).font(.system(size: 13)).foregroundStyle(Palette.ink2)
                        Text(verbatim: metric.title(in: project)).font(Typeface.title(26)).foregroundStyle(Palette.ink)
                    }
                    Spacer()
                    RoundIconButton(systemName: "xmark", label: String(localized: "关闭")) { dismiss() }
                }
                number
                card(String(localized: "一句话")) {
                    Text(verbatim: sentence)
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.ink)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isPeople && project.posthog != nil {
                    rules
                    check
                    sql
                }
                if project.posthog != nil, !model.settings.demoMode, isPeople {
                    Button("改口径") { editingCounting = true }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("metricSheetCounting")
                }
            }
            .padding(16)
        }
        .background(Palette.paper.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $editingCounting) { CountingEditor(project: project) }
        .task(id: project.metrics) {
            guard isPeople, project.metrics.dashboard != nil else { return }
            numbers = await model.dashboardNumbers(for: project)
        }
    }

    // MARK: Pieces

    private var number: some View {
        let reference = metric.reference(in: snapshot)
        let text = metric.text(snapshot?[metric])
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Odometer(text: text, size: NumberSize.fit(text, base: 64))
            if let reference {
                VStack(alignment: .leading, spacing: 2) {
                    Text(reference.text).font(.system(size: 15, weight: .bold)).foregroundStyle(reference.tone.color)
                    if metric.reference == .previousPeriod, let before = snapshot?.previous[metric] {
                        Text("上一个 7 天是 \(Format.number(Int(before)))").font(.system(size: 12)).foregroundStyle(Palette.ink2)
                    }
                }
            }
        }
    }

    /// The explanation, then the window it covers on a line of its own.
    private var sentence: String {
        [metric.explanation(in: project), window, thresholdNote].compactMap { $0 }.joined(separator: "\n")
    }

    /// What Google Play does about an Android vital past its threshold.
    private var thresholdNote: String? {
        metric.threshold.map { String(localized: "超过 \(Format.rate($0)) 时，Google Play 可能减少推荐，并在商店页提醒用户") }
    }

    /// The days the number covers, in the project's zone: "11/20 到 11/26，今天还没过完，按 UTC 分天".
    private var window: String? {
        let clock = ProjectClock(now: .now, timeZoneIdentifier: project.posthog?.timeZone)
        let zone = clock.timeZone
        let today = Format.day(clock.todayStart, in: zone)
        let days: Int? = switch metric {
        case .activeToday, .newUsers, .pageviews: 1
        case .activeWeek, .newWeek: 7
        case .activeMonth: 30
        default: nil
        }
        guard let days else { return nil }
        var parts = [days == 1
            ? String(localized: "\(today) 零点到现在")
            : String(localized: "\(Format.day(clock.historyStart(days: days), in: zone)) 到 \(today)，今天还没过完")]
        if let label = project.dayZoneLabel { parts.append(String(localized: "按 \(label) 分天")) }
        return parts.joined(separator: " · ")
    }

    private var rules: some View {
        card(String(localized: "怎么算")) {
            VStack(alignment: .leading, spacing: 0) {
                rule(String(localized: "数什么"), value: countedEvent, mono: true)
                RowDivider()
                HStack(alignment: .top, spacing: 12) {
                    Text("只算").font(.system(size: 13)).foregroundStyle(Palette.ink2).frame(width: 60, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        if settings.conditions.isEmpty && settings.surfacesLeftOut.isEmpty {
                            Text("这个项目的全部事件").font(.system(size: 14)).foregroundStyle(Palette.ink)
                        }
                        ForEach(settings.conditions, id: \.self) { condition in
                            Text(verbatim: condition)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Palette.ink)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Palette.pill, in: RoundedRectangle(cornerRadius: 6))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !settings.surfacesLeftOut.isEmpty {
                            Text(verbatim: project.scopeLine).font(.system(size: 13)).foregroundStyle(Palette.ink)
                        }
                    }
                }
                .padding(.vertical, 10)
                RowDivider()
                rule(String(localized: "一个是"), value: settings.unit == .install ? String(localized: "一次安装（distinct_id）") : String(localized: "一个人（PostHog 的人）"))
                if metric == .totalUsers {
                    RowDivider()
                    rule(String(localized: "从哪天起"), value: settings.since.map { Format.day($0, in: project.zone) } ?? String(localized: "全部历史"))
                }
            }
        }
    }

    /// The event the number counts: new users' own event, the activity event, or any.
    private var countedEvent: String {
        if metric == .newUsers || metric == .newWeek, case .event(let name) = settings.newUsers { return name }
        return settings.activityEvent ?? String(localized: "任何事件")
    }

    private func rule(_ label: String, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: label).font(.system(size: 13)).foregroundStyle(Palette.ink2).frame(width: 60, alignment: .leading)
            Text(verbatim: value)
                .font(mono ? .system(size: 14, weight: .semibold, design: .monospaced) : .system(size: 14))
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var check: some View {
        if let dashboard = settings.dashboard {
            let match = DashboardNumber.match(snapshot?[metric], in: numbers ?? [])
            HStack(alignment: .top, spacing: 12) {
                if numbers == nil {
                    ProgressView().controlSize(.small)
                    Text("正在和看板「\(dashboard.name)」对数…").font(.system(size: 14)).foregroundStyle(Palette.ink2)
                } else if let match {
                    Image(systemName: match.exact ? "checkmark.circle.fill" : "equal.circle.fill").font(.system(size: 22)).foregroundStyle(Palette.up)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(match.exact ? "和你的看板一致 · \(Format.number(Int(match.number.value)))" : "和你的看板差不多 · 看板是 \(Format.number(Int(match.number.value)))")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Palette.ink)
                        Text("对照的是「\(match.number.chart)」。两边隔几秒读，正在涨的数可能差一两个。")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Image(systemName: "questionmark.circle").font(.system(size: 22)).foregroundStyle(Palette.ink2)
                    Text("看板「\(dashboard.name)」里没有单独显示这个数，没法直接对照。条件是照着看板读的。")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(match != nil ? Palette.upSoft : Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else if !model.settings.demoMode {
            Button { editingCounting = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 18)).foregroundStyle(Palette.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("想和 PostHog 看板对上？").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
                        Text("让 Snuffle 从你的看板读口径，数字就按看板的条件算。").font(.system(size: 13)).foregroundStyle(Palette.ink2)
                    }
                    Spacer()
                    Image(systemName: "chevron.forward").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.ink2)
                }
                .padding(16)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var sql: some View {
        DisclosureGroup(isExpanded: $showingSQL) {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: hogql)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "拷贝")) { UIPasteboard.general.string = hogql }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .frame(minHeight: 44)
            }
            .padding(.top, 8)
        } label: {
            Text("看 HogQL").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
        }
        .tint(Palette.ink)
        .padding(16)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// The query Snuffle runs for this number, as it runs it now.
    private var hogql: String {
        let clock = ProjectClock(now: .now, timeZoneIdentifier: project.posthog?.timeZone)
        let scope = PeopleScope(settings, excluding: settings.surfacesLeftOut)
        switch metric {
        case .activeWeek: return PostHogQueries.peopleDays(scope, clock: clock)
        case .activeMonth: return PostHogQueries.month(scope, clock: clock)
        case .totalUsers: return PostHogQueries.tally(before: clock.todayStart, scope) + "\n\n" + PostHogQueries.firstSeen(scope, clock: clock)
        case .newUsers, .newWeek:
            if settings.newUsers == .firstSeen { return PostHogQueries.firstSeen(scope, clock: clock) }
            return PostHogQueries.counts(settings: settings, events: [], week: metric == .newWeek, clock: clock)?.sql ?? ""
        default: return PostHogQueries.peopleToday(scope, clock: clock)
        }
    }

    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title).font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.ink2)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
