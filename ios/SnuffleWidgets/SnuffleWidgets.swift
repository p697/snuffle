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

// MARK: Data (TodayEntry and the widget faces live in WidgetFaces.swift)

struct TodayProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TodayEntry { .placeholder }

    func snapshot(for configuration: TodayWidgetIntent, in context: Context) async -> TodayEntry {
        context.isPreview ? .placeholder : entry(configuration, now: .now)
    }

    func timeline(for configuration: TodayWidgetIntent, in context: Context) async -> Timeline<TodayEntry> {
        // The app learns which numbers widgets show, so its refreshes read them too.
        SharedContainer.recordWidgetMetrics([configuration.primary.metric] + [configuration.secondary?.metric].compactMap { $0 })
        // The app reloads widgets after each refresh; between refreshes only the "N 分钟前" label ages.
        let now = Date()
        let entries = (0..<4).map { step in entry(configuration, now: now.addingTimeInterval(Double(step) * 900)) }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(3600)))
    }

    private func entry(_ configuration: TodayWidgetIntent, now: Date) -> TodayEntry {
        TodayEntry.load(now: now, primary: configuration.primary.metric, secondary: configuration.secondary?.metric, project: configuration.project.isEveryProject ? nil : configuration.project.id)
    }
}

// MARK: Refresh from the widget

/// The widget's refresh button: reads every included project in the background and saves the result.
struct RefreshAllIntent: AppIntent {
    static let title: LocalizedStringResource = "刷新全部项目"
    static let description = IntentDescription("拉取每个项目卡片、项目看板和小组件上的数，以及评论。")

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
        let widgets = SharedContainer.widgetMetrics()
        for project in projects where project.includeInRefresh {
            let metrics = MetricsInUse.forProject(project, widgets: widgets)
            let result = await provider.refresh(project, metrics: metrics, previous: cache.snapshots[project.id], kept: cache.reviews[project.id] ?? [])
            cache.land(result, for: project)
        }
        cache.recordRefresh(at: Date())
        store.save(cache)
        return .result()
    }
}

// MARK: Widgets

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ai.snuffle.today", intent: TodayWidgetIntent.self, provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetPalette.card }
        }
        .configurationDisplayName("今日")
        .description("选一个数，看全部项目加起来或单个项目，按一下就刷新。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct LockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ai.snuffle.lock", intent: TodayWidgetIntent.self, provider: TodayProvider()) { entry in
            LockScreenView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("今日一行")
        .description("锁屏上看你选的数。")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
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
            Text(verbatim: "Snuffle Pro").font(.system(size: 15, weight: .heavy)).foregroundStyle(WidgetPalette.ink)
            Text("升级 Pro 后，小组件会显示今天的数字，还能直接刷新。")
                .font(.system(size: 12))
                .foregroundStyle(WidgetPalette.ink2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var refreshButton: some View {
        Button(intent: RefreshAllIntent()) {
            WidgetRefreshCircle(accent: entry.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("刷新全部项目")
    }

    private var small: some View {
        TodaySmallFace(entry: entry) { refreshButton }
    }

    private var medium: some View {
        TodayMediumFace(entry: entry) { refreshButton }
    }
}

struct LockScreenView: View {
    var entry: TodayEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if !entry.unlocked {
            Text(verbatim: "Snuffle Pro")
        } else if family == .accessoryInline {
            LockInlineFace(entry: entry)
        } else {
            LockRectangularFace(entry: entry)
        }
    }
}
