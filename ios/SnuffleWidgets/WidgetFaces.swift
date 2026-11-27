import SnuffleKit
import SwiftUI
import WidgetKit

/// What a widget draws: the same cache the app writes after every refresh, and the numbers its configuration picked.
nonisolated struct TodayEntry: TimelineEntry {
    struct Row: Identifiable {
        var id: UUID
        var name: String
        var monogram: String
        var tint: ProjectTint
        /// The project's picture, when the person chose one in the app.
        var icon: UIImage? = nil
        var values: [Metric: Double]
        var failed: Bool
    }

    var date: Date
    var rows: [Row]
    var lastRefresh: Date?
    var unlocked: Bool
    var demo: Bool
    var accent: AppSettings.Accent
    var primary: Metric = .newUsers
    var secondary: Metric? = .revenueMonth
    /// The one project picked in the configuration; nil adds up every project.
    var projectName: String?

    /// `metric` added up over the rows that have it; nil when none does.
    func total(_ metric: Metric) -> Double? {
        let values = rows.compactMap { $0.values[metric] }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    /// "新增用户 · 全部项目" or "MRR · Clawket", with "示例" in demo mode.
    var heading: String {
        [demo ? String(localized: "示例") : nil, primary.title, projectName].compactMap { $0 }.joined(separator: " · ")
    }

    static func load(now: Date = .now, primary: Metric = .newUsers, secondary: Metric? = .revenueMonth, project: UUID? = nil) -> TodayEntry {
        let settings = SharedContainer.settings.load() ?? AppSettings()
        let cache = (settings.demoMode ? SharedContainer.demoCache : SharedContainer.liveCache).load() ?? RefreshCache()
        let all = settings.demoMode ? DemoWorld.projects : (SharedContainer.workspace.load()?.projects ?? [])
        let chosen = project.flatMap { id in all.first { $0.id == id } }
        let projects = chosen.map { [$0] } ?? all.filter(\.includeInRefresh)
        let rows = projects.map { project in
            let snapshot = cache.snapshots[project.id]
            let icon = project.iconVersion.flatMap { UIImage(contentsOfFile: SharedContainer.projectIcon(project.id, version: $0).path()) }
            let values = (snapshot?.values ?? [:]).filter { $0.key.isAvailable(in: project) }
            return Row(id: project.id, name: project.name, monogram: project.monogram, tint: project.tint, icon: icon, values: values, failed: snapshot?.failures.contains { !settings.mutedSources.contains($0.platform) } ?? false)
        }
        let pro = UserDefaults(suiteName: SharedContainer.appGroup)?.bool(forKey: "isPro") ?? false
        return TodayEntry(
            date: now, rows: rows, lastRefresh: cache.lastRefresh, unlocked: pro || settings.demoMode,
            demo: settings.demoMode && !SharedContainer.hidesDemoMarks, accent: settings.accent,
            primary: primary, secondary: secondary, projectName: chosen?.name
        )
    }

    static let placeholder = TodayEntry(
        date: .now,
        rows: [
            Row(id: UUID(), name: "Lumen Notes", monogram: "L", tint: .ink, values: [.newUsers: 3_406, .revenueMonth: 26_480], failed: false),
            Row(id: UUID(), name: "Pocket Ferry", monogram: "P", tint: .coral, values: [.newUsers: 17, .revenueMonth: 142.5], failed: false),
            Row(id: UUID(), name: "Quiet Atlas", monogram: "Q", tint: .cocoa, values: [.newUsers: 45], failed: false)
        ],
        lastRefresh: .now.addingTimeInterval(-900),
        unlocked: true,
        demo: true,
        accent: .lemon
    )
}

nonisolated enum WidgetPalette {
    static let card = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.10, green: 0.10, blue: 0.09, alpha: 1) : .white })
    static let ink = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.96, green: 0.96, blue: 0.95, alpha: 1) : UIColor(red: 0.07, green: 0.07, blue: 0.06, alpha: 1) })
    static let ink2 = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.73, green: 0.73, blue: 0.69, alpha: 1) : UIColor(red: 0.33, green: 0.33, blue: 0.31, alpha: 1) })
    static let bad = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 1, green: 0.76, blue: 0.71, alpha: 1) : UIColor(red: 0.55, green: 0.14, blue: 0.07, alpha: 1) })
    static let onAccent = Color(red: 0.07, green: 0.07, blue: 0.06)

    static func accent(_ accent: AppSettings.Accent) -> Color {
        switch accent {
        case .lemon: Color(red: 1, green: 0.867, blue: 0.2)
        case .mint: Color(red: 0.486, green: 0.941, blue: 0.659)
        case .peach: Color(red: 1, green: 0.62, blue: 0.478)
        case .lilac: Color(red: 0.722, green: 0.651, blue: 1)
        }
    }

    static func tint(_ tint: ProjectTint) -> Color {
        switch tint {
        case .ink: ink
        case .coral: Color(red: 0.894, green: 0.341, blue: 0.18)
        case .cocoa: Color(red: 0.478, green: 0.337, blue: 0.267)
        case .ocean: Color(red: 0.184, green: 0.435, blue: 0.859)
        case .moss: Color(red: 0.247, green: 0.49, blue: 0.306)
        case .plum: Color(red: 0.482, green: 0.294, blue: 0.659)
        }
    }
}

nonisolated enum WidgetText {
    static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return String(localized: "还没刷新") }
        return Format.ago(date, now: now)
    }
}

/// The round refresh button's face, wrapped in an intent button by the widget.
struct WidgetRefreshCircle: View {
    var accent: AppSettings.Accent

    var body: some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(WidgetPalette.onAccent)
            .frame(width: 44, height: 44)
            .background(WidgetPalette.accent(accent), in: Circle())
    }
}

/// systemSmall: the big number, the line under it, and the refresh button.
struct TodaySmallFace<Refresh: View>: View {
    var entry: TodayEntry
    @ViewBuilder var refresh: Refresh

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.heading)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(WidgetPalette.ink2)
                .lineLimit(1)
            Text(entry.primary.format(entry.total(entry.primary) ?? 0))
                .font(.system(size: 44, weight: .heavy).width(.compressed))
                .foregroundStyle(WidgetPalette.ink)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(.numericText())
            if let secondary = entry.secondary, let value = entry.total(secondary) {
                Text(verbatim: "\(secondary.title) \(secondary.format(value))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WidgetPalette.ink)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                Text(WidgetText.ago(entry.lastRefresh, now: entry.date)).font(.system(size: 11)).foregroundStyle(WidgetPalette.ink2)
                Spacer()
                refresh
            }
        }
    }
}

/// systemMedium: up to three projects with the big number each (and the line's number beside it), and the button.
struct TodayMediumFace<Refresh: View>: View {
    var entry: TodayEntry
    @ViewBuilder var refresh: Refresh

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.heading + " · " + WidgetText.ago(entry.lastRefresh, now: entry.date))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WidgetPalette.ink2)
                    .lineLimit(1)
                ForEach(entry.rows.prefix(3)) { row in
                    HStack(spacing: 8) {
                        if let icon = row.icon {
                            Image(uiImage: icon)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 22, height: 22)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        } else {
                            Text(row.monogram)
                                .font(.system(size: 12, weight: .heavy))
                                .foregroundStyle(row.tint == .ink ? WidgetPalette.card : .white)
                                .frame(width: 22, height: 22)
                                .background(WidgetPalette.tint(row.tint), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        Text(row.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(WidgetPalette.ink).lineLimit(1)
                        Spacer(minLength: 4)
                        if row.failed {
                            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(WidgetPalette.bad)
                        }
                        if let secondary = entry.secondary, let value = row.values[secondary] {
                            Text(secondary.format(value)).font(.system(size: 12, weight: .semibold)).foregroundStyle(WidgetPalette.ink2).lineLimit(1)
                        }
                        Text(row.values[entry.primary].map(entry.primary.format) ?? "–")
                            .font(.system(size: 24, weight: .heavy).width(.compressed))
                            .foregroundStyle(WidgetPalette.ink)
                            .lineLimit(1)
                            .contentTransition(.numericText())
                    }
                }
                Spacer(minLength: 0)
            }
            VStack {
                Spacer()
                refresh
                Text("刷新").font(.system(size: 11, weight: .bold)).foregroundStyle(WidgetPalette.ink)
            }
        }
    }
}

/// accessoryRectangular: three lines on the lock screen.
struct LockRectangularFace: View {
    var entry: TodayEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: "\(entry.primary.title) · \(WidgetText.ago(entry.lastRefresh, now: entry.date))").font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(entry.primary.format(entry.total(entry.primary) ?? 0)).font(.system(size: 20, weight: .heavy).width(.compressed))
            if let secondary = entry.secondary, let value = entry.total(secondary) {
                Text(verbatim: "\(secondary.title) \(secondary.format(value))").font(.system(size: 13)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// accessoryInline: one line above the clock.
struct LockInlineFace: View {
    var entry: TodayEntry

    var body: some View {
        let first = "\(entry.primary.title) \(entry.primary.format(entry.total(entry.primary) ?? 0))"
        let second = entry.secondary.flatMap { metric in entry.total(metric).map { " · " + metric.format($0) } } ?? ""
        Text(first + second)
    }
}
