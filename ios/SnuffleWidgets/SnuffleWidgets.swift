import AppIntents
import SnuffleKit
import SwiftUI
import WidgetKit

@main
struct SnuffleWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        LockScreenWidget()
    }
}

// MARK: Data

/// What a widget draws: the same cache the app writes after every refresh.
struct TodayEntry: TimelineEntry {
    struct Row: Identifiable {
        var id: UUID
        var name: String
        var monogram: String
        var tint: ProjectTint
        var newUsers: Int?
        var revenue: Double?
        var failed: Bool
    }

    var date: Date
    var rows: [Row]
    var lastRefresh: Date?
    var unlocked: Bool
    var demo: Bool
    var accent: AppSettings.Accent

    var totalUsers: Int { rows.compactMap(\.newUsers).reduce(0, +) }
    var totalRevenue: Double? {
        let values = rows.compactMap(\.revenue)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    static func load(now: Date = .now) -> TodayEntry {
        let settings = SharedContainer.settings.load() ?? AppSettings()
        let cache = (settings.demoMode ? SharedContainer.demoCache : SharedContainer.liveCache).load() ?? RefreshCache()
        let projects = settings.demoMode ? DemoWorld.projects : (SharedContainer.workspace.load()?.projects ?? [])
        let rows = projects.filter(\.includeInRefresh).map { project in
            let snapshot = cache.snapshots[project.id]
            return Row(id: project.id, name: project.name, monogram: project.monogram, tint: project.tint, newUsers: snapshot?.newUsers, revenue: snapshot?.revenue, failed: !(snapshot?.failures.isEmpty ?? true))
        }
        let pro = UserDefaults(suiteName: SharedContainer.appGroup)?.bool(forKey: "isPro") ?? false
        return TodayEntry(date: now, rows: rows, lastRefresh: cache.lastRefresh, unlocked: pro || settings.demoMode, demo: settings.demoMode, accent: settings.accent)
    }

    static let placeholder = TodayEntry(
        date: .now,
        rows: [
            Row(id: UUID(), name: "Lumen Notes", monogram: "L", tint: .ink, newUsers: 3_406, revenue: 940, failed: false),
            Row(id: UUID(), name: "Pocket Ferry", monogram: "P", tint: .coral, newUsers: 17, revenue: 3.28, failed: false),
            Row(id: UUID(), name: "Quiet Atlas", monogram: "Q", tint: .cocoa, newUsers: 45, revenue: nil, failed: false)
        ],
        lastRefresh: .now.addingTimeInterval(-900),
        unlocked: true,
        demo: true,
        accent: .lemon
    )
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(context.isPreview ? .placeholder : .load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        // The app reloads widgets after each refresh; between refreshes only the "N 分钟前" label ages.
        let now = Date()
        let entries = (0..<4).map { step in
            var entry = TodayEntry.load(now: now.addingTimeInterval(Double(step) * 900))
            entry.date = now.addingTimeInterval(Double(step) * 900)
            return entry
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(3600))))
    }
}

// MARK: Refresh from the widget

/// The widget's refresh button: reads every included project in the background and saves the result.
struct RefreshAllIntent: AppIntent {
    static let title: LocalizedStringResource = "刷新全部项目"
    static let description = IntentDescription("拉取每个项目的最新新增用户、收入和评论。")

    func perform() async throws -> some IntentResult {
        let settings = SharedContainer.settings.load() ?? AppSettings()
        let store = settings.demoMode ? SharedContainer.demoCache : SharedContainer.liveCache
        var cache = store.load() ?? RefreshCache()
        let provider: any DataProvider
        let projects: [Project]
        if settings.demoMode {
            let demo = DemoProvider(world: SharedContainer.demoWorld.load(), latency: .zero) { SharedContainer.demoWorld.save($0) }
            await demo.advance()
            provider = demo
            projects = DemoWorld.projects
        } else {
            let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String
            let credentials = KeychainCredentialStore(accessGroup: prefix.map { $0 + SharedContainer.keychainGroupSuffix })
            provider = LiveProvider(tokens: TokenBroker(store: credentials))
            projects = SharedContainer.workspace.load()?.projects ?? []
        }
        for project in projects where project.includeInRefresh {
            let result = await provider.refresh(project)
            cache.snapshots[project.id] = result.snapshot.fillingGaps(from: cache.snapshots[project.id])
            if let reviews = result.reviews { cache.reviews[project.id] = reviews }
        }
        cache.recordRefresh(at: Date())
        store.save(cache)
        return .result()
    }
}

// MARK: Widgets

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ai.snuffle.today", provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetPalette.card }
        }
        .configurationDisplayName("今日")
        .description("所有项目今天的新增用户和收入，按一下就刷新。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct LockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ai.snuffle.lock", provider: TodayProvider()) { entry in
            LockScreenView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("今日一行")
        .description("锁屏上看今天的新增用户和收入。")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}

enum WidgetPalette {
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

private func number(_ value: Int) -> String {
    value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
}

private func money(_ value: Double) -> String {
    let rounded = (value * 100).rounded() / 100
    if abs(rounded - rounded.rounded()) < 0.005 { return "$" + number(Int(rounded.rounded())) }
    return "$" + String(format: "%.2f", rounded)
}

private func ago(_ date: Date?, now: Date) -> String {
    guard let date else { return "还没刷新" }
    let minutes = Int(now.timeIntervalSince(date) / 60)
    if minutes < 1 { return "刚刚" }
    if minutes < 60 { return "\(minutes) 分钟前" }
    return "\(minutes / 60) 小时前"
}

struct TodayWidgetView: View {
    var entry: TodayEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if !entry.unlocked {
            locked
        } else if entry.rows.isEmpty {
            Text("在 App 里添加项目后，这里会显示今天的数字。")
                .font(.system(size: 13))
                .foregroundStyle(WidgetPalette.ink2)
        } else if family == .systemSmall {
            small
        } else {
            medium
        }
    }

    private var locked: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Snuffle Pro").font(.system(size: 15, weight: .heavy)).foregroundStyle(WidgetPalette.ink)
            Text("升级 Pro 后，小组件会显示今天的数字，还能直接刷新。")
                .font(.system(size: 12))
                .foregroundStyle(WidgetPalette.ink2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var refreshButton: some View {
        Button(intent: RefreshAllIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(WidgetPalette.onAccent)
                .frame(width: 44, height: 44)
                .background(WidgetPalette.accent(entry.accent), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("刷新全部项目")
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.demo ? "今日新增 · 示例" : "今日新增")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(WidgetPalette.ink2)
            Text(number(entry.totalUsers))
                .font(.system(size: 44, weight: .heavy).width(.compressed))
                .foregroundStyle(WidgetPalette.ink)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(.numericText())
            if let revenue = entry.totalRevenue {
                Text("收入 \(money(revenue))").font(.system(size: 13, weight: .semibold)).foregroundStyle(WidgetPalette.ink)
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                Text(ago(entry.lastRefresh, now: entry.date)).font(.system(size: 11)).foregroundStyle(WidgetPalette.ink2)
                Spacer()
                refreshButton
            }
        }
    }

    private var medium: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(entry.demo ? "示例 · " : "")今日新增 · \(ago(entry.lastRefresh, now: entry.date))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WidgetPalette.ink2)
                ForEach(entry.rows.prefix(3)) { row in
                    HStack(spacing: 8) {
                        Text(row.monogram)
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(row.tint == .ink ? WidgetPalette.card : .white)
                            .frame(width: 22, height: 22)
                            .background(WidgetPalette.tint(row.tint), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(row.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(WidgetPalette.ink).lineLimit(1)
                        Spacer(minLength: 4)
                        if row.failed {
                            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(WidgetPalette.bad)
                        }
                        Text(row.newUsers.map(number) ?? "–")
                            .font(.system(size: 24, weight: .heavy).width(.compressed))
                            .foregroundStyle(WidgetPalette.ink)
                            .contentTransition(.numericText())
                    }
                }
                Spacer(minLength: 0)
            }
            VStack {
                Spacer()
                refreshButton
                Text("刷新").font(.system(size: 11, weight: .bold)).foregroundStyle(WidgetPalette.ink)
            }
        }
    }
}

struct LockScreenView: View {
    var entry: TodayEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if !entry.unlocked {
            Text("Snuffle Pro")
        } else if family == .accessoryInline {
            Text("新增 \(number(entry.totalUsers))" + (entry.totalRevenue.map { " · \(money($0))" } ?? ""))
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text("今日 · \(ago(entry.lastRefresh, now: entry.date))").font(.system(size: 12, weight: .semibold))
                Text("+\(number(entry.totalUsers)) 用户").font(.system(size: 20, weight: .heavy).width(.compressed))
                if let revenue = entry.totalRevenue { Text("收入 \(money(revenue))").font(.system(size: 13)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
