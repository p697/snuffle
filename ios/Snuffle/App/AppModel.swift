import Observation
import SnuffleKit
import SwiftUI
import WidgetKit

/// Where a project card is in the refresh sequence. Its numbers stay on screen throughout.
enum CardStage: Equatable {
    case rest
    /// Waiting its turn.
    case waiting
    /// Its turn: lifted, a short stroke running round its outline.
    case loading
    /// Changed digits are rolling up to the new value.
    case landed
}

/// The cat behind the refresh button.
struct CatState: Equatable {
    enum Reaction: Equatable { case glee, cheer, blink, flat }

    var out = false
    var sniffing = false
    var ducking = false
    var reaction: Reaction?
    /// Bumped to replay the same reaction twice in a row.
    var reactionToken = 0
}

/// App-wide state and the refresh choreography. Views read it; only its methods change it.
@MainActor
@Observable
final class AppModel {
    // MARK: Stored state

    private(set) var settings: AppSettings
    private(set) var workspace: Workspace
    private(set) var cache: RefreshCache

    let credentials: any CredentialStore
    let feedback = Feedback()
    let pro: ProStore
    let cloud: CloudClient

    private var demo: DemoProvider?
    private var live: LiveProvider

    // MARK: Refresh choreography

    private(set) var isRefreshing = false
    private(set) var stages: [UUID: CardStage] = [:]
    /// What went up on each card in the latest refresh; shown as the highlighter and "+N" until it fades.
    private(set) var marks: [UUID: SnapshotChange] = [:]
    private(set) var marksFading = false
    /// Sum of this refresh's changes across projects, for the 收入 tab.
    private(set) var refreshMark: SnapshotChange?
    /// Bumped when a card should shake for a failed source.
    private(set) var shakes: [UUID: Int] = [:]
    private(set) var cat = CatState()
    /// Progress of the current refresh (0…1) for the ring around the button.
    private(set) var refreshProgress: Double = 0

    private var fadeTask: Task<Void, Never>?

    // MARK: Connecting

    /// A key file opened in Snuffle from Files or AirDrop, waiting for the App Store connect page to take it.
    var openedKeyFile: KeyFile?
    /// How many connect flows are on screen, so an opened key file joins one instead of starting another.
    var openConnectFlows = 0

    /// Mark stay time chosen with the user: five seconds after the last card lands.
    static let markStay: Duration = .seconds(5)
    /// Ten minutes after a refresh the cat starts flicking an ear: time to refresh again.
    static let chargeDuration: TimeInterval = 600
    static let freeProjectLimit = 2

    init(credentials: any CredentialStore, pro: ProStore, cloud: CloudClient) {
        self.credentials = credentials
        self.pro = pro
        self.cloud = cloud
        let settings = SharedContainer.settings.load() ?? AppSettings()
        self.settings = settings
        workspace = SharedContainer.workspace.load() ?? Workspace()
        cache = (settings.demoMode ? SharedContainer.demoCache : SharedContainer.liveCache).load() ?? RefreshCache()
        live = LiveProvider(tokens: TokenBroker(store: credentials))
        feedback.hapticsOn = settings.haptics
        feedback.soundOn = settings.sound
        if settings.demoMode { startDemo() }
        applyLaunchArguments()
        syncAnalytics()
    }

    private func syncAnalytics() {
        Analytics.setWorkspace(demoMode: settings.demoMode, projectCount: workspace.projects.count)
    }

    // MARK: Derived

    var provider: any DataProvider { demo ?? live }

    var projects: [Project] { settings.demoMode ? DemoWorld.projects : workspace.projects }

    /// Projects a refresh reads: the person's choice, and at most two without Pro.
    var refreshable: [Project] {
        let included = projects.filter(\.includeInRefresh)
        return settings.demoMode || pro.isPro ? included : Array(included.prefix(Self.freeProjectLimit))
    }

    func isLocked(_ project: Project) -> Bool {
        guard !settings.demoMode, !pro.isPro else { return false }
        return !projects.prefix(Self.freeProjectLimit).contains { $0.id == project.id }
    }

    /// A new project fits: always with Pro, otherwise while under the free limit.
    var canAddProject: Bool { pro.isPro || workspace.projects.count < Self.freeProjectLimit }

    var needsOnboarding: Bool { !settings.demoMode && workspace.projects.isEmpty }

    /// Debug builds launched with `-storeShots` take App Store screenshots: no "示例" marks, and a demo day that has
    /// reached the evening whatever the time.
    private static var storeShots: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-storeShots")
        #else
        false
        #endif
    }

    /// Whether screens say the numbers are samples (`SharedContainer.hidesDemoMarks`).
    var marksDemo: Bool { settings.demoMode && !SharedContainer.hidesDemoMarks }

    func snapshot(_ projectId: UUID) -> ProjectSnapshot? { cache.snapshots[projectId] }

    func stage(_ projectId: UUID) -> CardStage { stages[projectId] ?? .rest }

    var allReviews: [Review] {
        let ids = Set(projects.map(\.id))
        return cache.reviews.filter { ids.contains($0.key) }.flatMap(\.value).sorted { $0.createdAt > $1.createdAt }
    }

    /// `metric` added up across projects (today's revenue on the 收入 tab); nil when no project has it.
    func total(_ metric: Metric) -> Double? {
        let values = projects.compactMap { project in metric.isAvailable(in: project) ? cache.snapshots[project.id]?[metric] : nil }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    /// What a project's card shows, leaving out numbers from sources it does not have.
    func layout(_ project: Project) -> CardLayout { project.card.visible(in: project) }

    /// The numbers a refresh reads for `project`: its card, its board's four and the placed widgets.
    func metricsInUse(_ project: Project) -> Set<Metric> {
        MetricsInUse.forProject(project, widgets: SharedContainer.widgetMetrics())
    }

    var lastRefresh: Date? { cache.lastRefresh }

    var refreshCountToday: Int {
        guard let day = cache.refreshDay, Calendar.current.isDateInToday(day) else { return 0 }
        return cache.refreshCountToday
    }

    // MARK: Refresh

    /// Finger down on the button: the cat ducks.
    func pressBegan() {
        guard !isRefreshing else { return }
        cat.ducking = true
        feedback.press()
        feedback.prepare()
    }

    func pressEnded() {
        cat.ducking = false
    }

    /// Refreshes every included project, revealing them one after another.
    func refreshAll(trigger: Analytics.RefreshTrigger = .manual) async {
        await refresh(refreshable, trigger: trigger)
    }

    func refresh(_ projects: [Project], trigger: Analytics.RefreshTrigger) async {
        guard !isRefreshing, !projects.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let refreshStarted = ContinuousClock.now

        feedback.release()
        clearMarks()
        refreshProgress = 0
        cat = CatState(out: true, sniffing: true)
        for project in projects { stages[project.id] = .waiting }

        if let demo { await demo.advance() }
        // Every project is fetched at once; only the reveal is sequential.
        let provider = self.provider
        let fetches = projects.map { project in
            let metrics = metricsInUse(project)
            let previous = cache.snapshots[project.id]
            let kept = cache.reviews[project.id] ?? []
            return (project, Task { await provider.refresh(project, metrics: metrics, previous: previous, kept: kept) })
        }
        try? await Task.sleep(for: .milliseconds(380))

        var total = SnapshotChange.none
        var anySale = false
        var failedProjects = 0
        for (index, (project, fetch)) in fetches.enumerated() {
            stages[project.id] = .loading
            let started = ContinuousClock.now
            let result = await fetch.value
            let elapsed = ContinuousClock.now - started
            if elapsed < .milliseconds(650) { try? await Task.sleep(for: .milliseconds(650) - elapsed) }

            adoptTimeZone(result.posthogTimeZone, for: project.id)
            adoptSurfaces(result.excludedSurfaces, for: project.id)
            let previous = cache.snapshots[project.id]
            let snapshot = cache.land(result, for: project)
            let layout = self.layout(project)
            // A sale is always celebrated and shown on the 收入 tab, wherever revenue is placed (or not).
            let change = SnapshotChange(from: previous, to: snapshot, metrics: layout.metrics + MetricsInUse.board + [.revenue, .orders])
            stages[project.id] = .landed

            let headline = layout.big[0]
            let digits = headline.format(snapshot[headline] ?? 0).filter(\.isNumber).count
            playTicks(columns: digits)
            try? await Task.sleep(for: Self.landDuration(columns: digits) + .milliseconds(60))

            if change.isNews {
                marks[project.id] = change
                total.add(change)
                refreshMark = total
                // New reviews get a mark but no celebration: they are not always good news.
                if change.isUp { react(.glee) }
                if change.hasSale {
                    anySale = true
                    feedback.sale()
                }
            }
            if !snapshot.failures.isEmpty {
                failedProjects += 1
                result.snapshot.failures.forEach(Analytics.refreshSourceFailed)
                shakes[project.id, default: 0] += 1
                react(.flat)
                feedback.warning()
            }
            refreshProgress = Double(index + 1) / Double(fetches.count)
            try? await Task.sleep(for: .milliseconds(300))
            stages[project.id] = .rest
        }

        cache.recordRefresh(at: Date())
        saveCache()
        followDashboards(projects)
        Analytics.refreshCompleted(
            trigger: trigger, projects: projects.count, failedProjects: failedProjects,
            wentUp: total.isUp, sale: anySale, duration: ContinuousClock.now - refreshStarted
        )
        WidgetCenter.shared.reloadAllTimelines()
        scheduleFade()

        cat.sniffing = false
        let finale: CatState.Reaction = anySale ? .cheer : total.isUp ? .glee : failedProjects > 0 ? .flat : .blink
        react(finale)
        try? await Task.sleep(for: finale == .cheer ? .milliseconds(1250) : .milliseconds(900))
        cat = CatState()
        refreshProgress = 0
    }

    /// Time for changed digits to roll up to their new value (`Odometer`).
    static func landDuration(columns: Int) -> Duration {
        .milliseconds(600 + max(0, columns - 1) * 90)
    }

    private func playTicks(columns: Int) {
        for column in 0..<columns {
            Task { [feedback] in
                try? await Task.sleep(for: .milliseconds(column * 110))
                feedback.tick(column: column)
            }
        }
    }

    private func react(_ reaction: CatState.Reaction) {
        cat.reaction = reaction
        cat.reactionToken += 1
        let token = cat.reactionToken
        Task {
            try? await Task.sleep(for: reaction == .cheer ? .milliseconds(1200) : .milliseconds(560))
            if cat.reactionToken == token { cat.reaction = nil }
        }
    }

    private func clearMarks() {
        fadeTask?.cancel()
        marks = [:]
        refreshMark = nil
        marksFading = false
    }

    private func scheduleFade() {
        fadeTask?.cancel()
        fadeTask = Task {
            try? await Task.sleep(for: Self.markStay)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.4)) { marksFading = true }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            marks = [:]
            refreshMark = nil
            marksFading = false
        }
    }

    /// Refreshes when the app comes to the front, at most once every two minutes.
    func refreshOnOpenIfNeeded() async {
        guard settings.refreshOnOpen, !needsOnboarding else { return }
        if let last = cache.lastRefresh, Date().timeIntervalSince(last) < 120 { return }
        await refreshAll(trigger: .open)
    }

    // MARK: Reviews

    func reply(to review: Review, text: String) async throws {
        guard let project = projects.first(where: { $0.id == review.projectId }) else { return }
        try await provider.reply(to: review, text: text, in: project)
        if var list = cache.reviews[project.id], let index = list.firstIndex(where: { $0.id == review.id }) {
            list[index].reply = ReviewReply(text: text, date: Date(), pending: review.platform == .appStore)
            cache.reviews[project.id] = list
            cache.snapshots[project.id]?[.reviewsToAnswer] = Double(list.filter(\.needsReply).count)
            saveCache()
        }
    }

    func draftReply(for review: Review) async throws -> ReplyDraft {
        let appName = projects.first { $0.id == review.projectId }?.name ?? ""
        if settings.demoMode {
            try? await Task.sleep(for: .milliseconds(900))
            return ReplyDraft.demo(for: review, appName: appName)
        }
        return try await cloud.draftReply(review: review, appName: appName, tone: settings.replyTone, signature: settings.replySignature, proof: await pro.entitlementProof())
    }

    // MARK: Workspace

    /// Follows a time zone changed in PostHog after the project was connected; the next refresh counts by it.
    private func adoptTimeZone(_ zone: String?, for projectId: UUID) {
        guard let zone, TimeZone(identifier: zone) != nil,
              let index = workspace.projects.firstIndex(where: { $0.id == projectId }),
              let link = workspace.projects[index].posthog, link.timeZone != zone else { return }
        workspace.projects[index].posthog?.timeZone = zone
        SharedContainer.workspace.save(workspace)
    }

    /// Keeps the surfaces a refresh chose for a project whose person never picked, so it looks only once.
    private func adoptSurfaces(_ excluded: Set<Surface>?, for projectId: UUID) {
        guard let excluded, let index = workspace.projects.firstIndex(where: { $0.id == projectId }),
              workspace.projects[index].metrics.excludedSurfaces == nil else { return }
        workspace.projects[index].metrics.excludedSurfaces = excluded
        SharedContainer.workspace.save(workspace)
    }

    func save(project: Project) {
        let index = workspace.projects.firstIndex { $0.id == project.id }
        if let index {
            // Google Play reviews are kept across refreshes; another app's are not this one's.
            if let before = workspace.projects[index].googlePlay?.packageName, before != project.googlePlay?.packageName {
                cache.forgetReviews(from: .googlePlay, of: project.id)
                saveCache()
            }
            workspace.projects[index] = project
        } else {
            workspace.projects.append(project)
        }
        SharedContainer.workspace.save(workspace)
        syncAnalytics()
        Analytics.projectSaved(project, isNew: index == nil, projectCount: workspace.projects.count)
        SharedContainer.removeProjectIcons(project.id, keeping: project.iconVersion)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Saves a card layout for `project`, or for every project when `everywhere` (each project's own events stay
    /// on its own card), then reads any number that is now shown but was never read, and `project` again when its
    /// sources or counting changed (`countingChanged`).
    func saveCard(_ layout: CardLayout, for project: Project, everywhere: Bool, dragged: Bool = false, countingChanged: Bool = false, measured: [Metric: Double] = [:]) {
        var changed: [Project] = []
        for index in workspace.projects.indices {
            var target = workspace.projects[index]
            if target.id == project.id {
                target = project
                target.card = layout
            } else if everywhere {
                // This project's own events keep their places where the shared layout leaves room.
                var card = CardLayout(big: layout.big.filter(\.isShared), rows: layout.rows.map { $0.filter(\.isShared) }, trend: layout.trend, split: layout.split)
                for metric in target.card.metrics where !metric.isShared {
                    if let opening = card.openings.first { card = card.placing(metric, at: opening) }
                }
                target.card = card
            } else {
                continue
            }
            workspace.projects[index] = target
            changed.append(target)
        }
        SharedContainer.workspace.save(workspace)
        // What the library just read is today's number too: keep it rather than reading it again.
        if !countingChanged, !measured.isEmpty, var snapshot = cache.snapshots[project.id] {
            // Unless the cache was read under other counting, whose numbers the next refresh replaces anyway.
            let current = snapshot.countedAs == project.metrics.inEffect
            snapshot.values.merge(measured.filter { current || !$0.key.followsCounting }) { $1 }
            cache.snapshots[project.id] = snapshot
            saveCache()
        }
        Analytics.cardLayoutSaved(layout, everywhere: everywhere, dragged: dragged)
        WidgetCenter.shared.reloadAllTimelines()
        let unread = changed.filter { target in
            if countingChanged && target.id == project.id { return true }
            let snapshot = cache.snapshots[target.id]
            return self.layout(target).metrics.contains { snapshot?[$0] == nil }
        }
        if !unread.isEmpty { Task { await refresh(unread, trigger: .project) } }
    }

    // MARK: Boards and dashboards

    /// Looks once at the dashboards of projects added before Snuffle read them, and counts the way they do when they
    /// say so on purpose. A project whose dashboards cannot be read yet (an account without the new permission) is
    /// looked at again after the next refresh.
    private func followDashboards(_ refreshed: [Project]) {
        guard !settings.demoMode else { return }
        let unchecked = refreshed.filter { $0.posthog != nil && !$0.dashboardChecked }
        guard !unchecked.isEmpty else { return }
        let provider = self.provider
        Task {
            for project in unchecked {
                // `try?` would fold "no counting" into "could not read"; only the second is looked at again.
                let found: DashboardReading.Counting?
                do { found = try await provider.dashboardCounting(for: project) } catch { continue }
                guard let index = workspace.projects.firstIndex(where: { $0.id == project.id }), !workspace.projects[index].dashboardChecked else { continue }
                var current = workspace.projects[index]
                current.dashboardChecked = true
                // Only Snuffle's own counting is replaced: one the person set up stays theirs.
                let follow = found.flatMap { current.metrics.isStandardPeople ? $0 : nil }
                if let follow {
                    current.metrics = follow.applied(to: current.metrics, timeZone: current.zone)
                    Analytics.countingChanged(.dashboard, settings: current.metrics)
                }
                workspace.projects[index] = current
                SharedContainer.workspace.save(workspace)
                guard follow != nil else { continue }
                boards[current.id] = nil
                while isRefreshing { try? await Task.sleep(for: .milliseconds(300)) }
                await refresh([current], trigger: .project)
            }
        }
    }

    /// Boards read while the app is open, by project and range, so going back to a project shows it at once.
    private(set) var boards: [UUID: [Int: ProjectBoard]] = [:]
    /// The last result of each chart placed on a board, by chart id.
    private(set) var insightResults: [Int: InsightResult] = [:]

    /// Reads a project's board for the last `days` days; today's total by platform gives the daily totals.
    func loadBoard(_ project: Project, days: Int) async throws {
        let total = cache.snapshots[project.id].map { Dictionary($0.platforms.map { ($0.name, $0.count) }, uniquingKeysWith: +) }
        let board = try await provider.board(for: project, days: days, total: total?.isEmpty == false ? total : nil)
        boards[project.id, default: [:]][days] = board
    }

    /// Runs every chart placed on a project's board, each on its own; one that fails keeps its last result.
    func runPins(_ project: Project) async -> [Int: Error] {
        let provider = self.provider
        return await withTaskGroup(of: (Int, Result<InsightResult, Error>).self) { group in
            for tile in project.pins where tile.canDraw {
                group.addTask {
                    do { return (tile.id, .success(try await provider.run(tile, for: project))) } catch { return (tile.id, .failure(error)) }
                }
            }
            var failures: [Int: Error] = [:]
            for await (id, result) in group {
                switch result {
                case .success(let value): insightResults[id] = value
                case .failure(let error): failures[id] = error
                }
            }
            return failures
        }
    }

    /// The single numbers on a project's counting dashboard, read at most every five minutes, to set Snuffle's numbers
    /// beside the dashboard's own.
    private var dashboardNumbers: [Int: (read: Date, numbers: [DashboardNumber])] = [:]

    func dashboardNumbers(for project: Project) async -> [DashboardNumber] {
        guard let ref = project.metrics.dashboard else { return [] }
        if let cached = dashboardNumbers[ref.id], Date().timeIntervalSince(cached.read) < 300 { return cached.numbers }
        guard let detail = try? await provider.dashboard(ref, for: project) else { return [] }
        let tiles = detail.tiles.filter { $0.canDraw && ($0.display == "BoldNumber" || $0.kind == .table) }.prefix(12)
        let provider = self.provider
        let numbers = await withTaskGroup(of: [DashboardNumber].self) { group in
            for tile in tiles {
                group.addTask {
                    guard let result = try? await provider.run(tile, for: project) else { return [] }
                    let found = result.numbers(for: tile)
                    return found.map { DashboardNumber(chart: found.count > 1 ? "\(tile.name) · \($0.name)" : tile.name, value: $0.value, previous: $0.previous) }
                }
            }
            var all: [DashboardNumber] = []
            for await batch in group { all += batch }
            return all
        }
        dashboardNumbers[ref.id] = (Date(), numbers)
        return numbers
    }

    func keep(_ result: InsightResult, for tile: InsightTile) {
        insightResults[tile.id] = result
    }

    /// Places charts on a project's board, in the order given.
    func pin(_ tiles: [InsightTile], on project: Project) {
        guard var current = workspace.projects.first(where: { $0.id == project.id }) else { return }
        let added = tiles.filter { tile in !current.pins.contains { $0.id == tile.id } }
        current.pins = tiles
        save(project: current)
        if !added.isEmpty { Analytics.chartsPinned(added.count, total: tiles.count) }
    }

    /// Counts a project's people another way and reads its numbers again under it.
    func applyCounting(_ settings: MetricSettings, to project: Project, source: Analytics.CountingSource) {
        guard var current = workspace.projects.first(where: { $0.id == project.id }), current.metrics != settings else { return }
        current.metrics = settings
        save(project: current)
        boards[project.id] = nil
        Analytics.countingChanged(source, settings: settings)
        Task { await refresh([current], trigger: .project) }
    }

    func delete(project: Project) {
        workspace.projects.removeAll { $0.id == project.id }
        SharedContainer.removeProjectIcons(project.id)
        cache.snapshots[project.id] = nil
        cache.reviews[project.id] = nil
        SharedContainer.workspace.save(workspace)
        saveCache()
        WidgetCenter.shared.reloadAllTimelines()
        syncAnalytics()
        Analytics.projectDeleted(project, projectCount: workspace.projects.count)
    }

    func moveProjects(from source: IndexSet, to destination: Int) {
        workspace.projects.move(fromOffsets: source, toOffset: destination)
        SharedContainer.workspace.save(workspace)
    }

    /// Saves a newly connected account, reusing an existing one with the same title on the same platform.
    @discardableResult
    func add(account: Account, credential: Credential) throws -> Account {
        var account = account
        if let existing = workspace.accounts.first(where: { $0.platform == account.platform && $0.title == account.title && $0.subtitle == account.subtitle }) {
            account.id = existing.id
        }
        try credentials.save(credential, for: account.id)
        workspace.accounts.removeAll { $0.id == account.id }
        workspace.accounts.append(account)
        SharedContainer.workspace.save(workspace)
        return account
    }

    /// Removes an account and every project link that used it.
    func remove(account: Account) {
        try? credentials.delete(accountId: account.id)
        workspace.accounts.removeAll { $0.id == account.id }
        for index in workspace.projects.indices {
            var project = workspace.projects[index]
            if project.posthog?.accountId == account.id { project.posthog = nil }
            if project.revenueCat?.accountId == account.id { project.unlink(.revenueCat) }
            if project.appStore?.accountId == account.id { project.appStore = nil }
            if project.googlePlay?.accountId == account.id { project.googlePlay = nil }
            workspace.projects[index] = project
        }
        SharedContainer.workspace.save(workspace)
        Analytics.accountRemoved(account.platform)
    }

    // MARK: Settings

    func update(_ change: (inout AppSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let modeChanged = next.demoMode != settings.demoMode
        settings = next
        feedback.hapticsOn = next.haptics
        feedback.soundOn = next.sound
        SharedContainer.settings.save(next)
        if modeChanged {
            switchMode()
            syncAnalytics()
            Analytics.demoModeChanged(enabled: next.demoMode)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func switchMode() {
        clearMarks()
        stages = [:]
        if settings.demoMode {
            startDemo()
        } else {
            demo = nil
        }
        cache = (settings.demoMode ? SharedContainer.demoCache : SharedContainer.liveCache).load() ?? RefreshCache()
    }

    private func startDemo() {
        let provider = DemoProvider(world: SharedContainer.demoWorld.load(), lateInDay: Self.storeShots, persist: { SharedContainer.demoWorld.save($0) })
        demo = provider
        Task { await seedDemoIfEmpty(provider) }
    }

    /// Fills an empty demo cache (or one saved before metrics had ids) with today's sample numbers, so the first
    /// screen is never a row of dashes.
    private func seedDemoIfEmpty(_ provider: DemoProvider) async {
        guard settings.demoMode, cache.snapshots.isEmpty || cache.snapshots.values.contains(where: \.values.isEmpty) else { return }
        for result in await provider.seed() {
            guard let project = DemoWorld.projects.first(where: { $0.id == result.snapshot.projectId }) else { continue }
            cache.land(result, for: project)
        }
        saveCache()
    }

    func setDemoScenario(_ scenario: DemoWorld.Scenario) async {
        await demo?.setScenario(scenario)
    }

    private func saveCache() {
        (settings.demoMode ? SharedContainer.demoCache : SharedContainer.liveCache).save(cache)
    }

    /// UI tests start in demo mode with a known scenario: `-demo` and `-scenario sale|quiet|failure`.
    private func applyLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        SharedContainer.hidesDemoMarks = Self.storeShots
        if arguments.contains("-resetState") {
            for store in [SharedContainer.liveCache.url, SharedContainer.demoCache.url, SharedContainer.demoWorld.url, SharedContainer.workspace.url, SharedContainer.settings.url] {
                try? FileManager.default.removeItem(at: store)
            }
            settings = AppSettings()
            workspace = Workspace()
            cache = RefreshCache()
            demo = nil
        }
        if arguments.contains("-demo") {
            settings.demoMode = true
            settings.refreshOnOpen = false
            // Saved like a normal switch, so the widget shows the same demo numbers.
            SharedContainer.settings.save(settings)
            if demo == nil { startDemo() }
            cache = SharedContainer.demoCache.load() ?? RefreshCache()
        }
        #if DEBUG
        // UI tests of the project pages outside demo mode: the sample projects as the person's own, no accounts.
        if arguments.contains("-sampleWorkspace") {
            settings.refreshOnOpen = false
            workspace = Workspace(projects: DemoWorld.projects)
            SharedContainer.workspace.save(workspace)
        }
        #endif
        if let index = arguments.firstIndex(of: "-scenario"), index + 1 < arguments.count,
           let scenario = DemoWorld.Scenario(rawValue: arguments[index + 1]) {
            Task { await demo?.setScenario(scenario) }
        }
    }
}
