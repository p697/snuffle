import Observation
import SnuffleKit
import SwiftUI
import WidgetKit

/// Where a project card is in the refresh sequence.
enum CardStage: Equatable {
    case rest
    /// Waiting its turn: dimmed.
    case waiting
    /// Its turn: lifted, digits spinning.
    case loading
    /// Digits have landed on the new value.
    case landed
}

extension ProjectSnapshot {
    /// The card's big number: new users when PostHog is connected, otherwise reviews waiting for a reply.
    func headline(for project: Project) -> Int? {
        project.posthog != nil ? newUsers : reviewsToAnswer
    }
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
    /// Sum of this refresh's changes, for the totals strip.
    private(set) var totalsMark: SnapshotChange?
    /// Bumped when a card should shake for a failed source.
    private(set) var shakes: [UUID: Int] = [:]
    /// Bumped when a card checked and nothing changed, for the settle flash.
    private(set) var settles: [UUID: Int] = [:]
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

    var needsOnboarding: Bool { !settings.demoMode && workspace.projects.isEmpty }

    func snapshot(_ projectId: UUID) -> ProjectSnapshot? { cache.snapshots[projectId] }

    func stage(_ projectId: UUID) -> CardStage { stages[projectId] ?? .rest }

    var allReviews: [Review] {
        let ids = Set(projects.map(\.id))
        return cache.reviews.filter { ids.contains($0.key) }.flatMap(\.value).sorted { $0.createdAt > $1.createdAt }
    }

    var totals: (newUsers: Int, revenue: Double, reviewsToAnswer: Int, hasUsers: Bool, hasRevenue: Bool, hasReviews: Bool) {
        let snapshots = projects.compactMap { cache.snapshots[$0.id] }
        return (
            snapshots.compactMap(\.newUsers).reduce(0, +),
            snapshots.compactMap(\.revenue).reduce(0, +),
            snapshots.compactMap(\.reviewsToAnswer).reduce(0, +),
            snapshots.contains { $0.newUsers != nil },
            snapshots.contains { $0.revenue != nil },
            snapshots.contains { $0.reviewsToAnswer != nil }
        )
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
    func refreshAll() async {
        await refresh(refreshable)
    }

    func refresh(_ projects: [Project]) async {
        guard !isRefreshing, !projects.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        feedback.release()
        clearMarks()
        refreshProgress = 0
        cat = CatState(out: true, sniffing: true)
        for project in projects { stages[project.id] = .waiting }

        if let demo { await demo.advance() }
        // Every project is fetched at once; only the reveal is sequential.
        let provider = self.provider
        let fetches = projects.map { project in (project, Task { await provider.refresh(project) }) }
        try? await Task.sleep(for: .milliseconds(380))

        var total = SnapshotChange.none
        var anySale = false
        var anyFailure = false
        for (index, (project, fetch)) in fetches.enumerated() {
            stages[project.id] = .loading
            let started = ContinuousClock.now
            let result = await fetch.value
            let elapsed = ContinuousClock.now - started
            if elapsed < .milliseconds(650) { try? await Task.sleep(for: .milliseconds(650) - elapsed) }

            let previous = cache.snapshots[project.id]
            let snapshot = result.snapshot.fillingGaps(from: previous)
            let change = SnapshotChange(from: previous, to: snapshot)
            cache.snapshots[project.id] = snapshot
            if let reviews = result.reviews { cache.reviews[project.id] = reviews }
            stages[project.id] = .landed

            let digits = Format.number(snapshot.headline(for: project) ?? 0).filter(\.isNumber).count
            playTicks(columns: digits)
            try? await Task.sleep(for: Self.landDuration(columns: digits) + .milliseconds(60))

            if change.isNews {
                marks[project.id] = change
                total.newUsers += change.newUsers
                total.revenue += change.revenue
                total.sales += change.sales
                total.reviews += change.reviews
                totalsMark = total
                // New reviews get a mark but no celebration: they are not always good news.
                if change.isUp { react(.glee) }
                if change.hasSale {
                    anySale = true
                    feedback.sale()
                }
            } else {
                settles[project.id, default: 0] += 1
            }
            if !snapshot.failures.isEmpty {
                anyFailure = true
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
        WidgetCenter.shared.reloadAllTimelines()
        scheduleFade()

        cat.sniffing = false
        let finale: CatState.Reaction = anySale ? .cheer : total.isUp ? .glee : anyFailure ? .flat : .blink
        react(finale)
        try? await Task.sleep(for: finale == .cheer ? .milliseconds(1250) : .milliseconds(900))
        cat = CatState()
        refreshProgress = 0
    }

    /// Time for every digit column to land: 420 ms each, 110 ms apart, left to right.
    static func landDuration(columns: Int) -> Duration {
        .milliseconds(420 + max(0, columns - 1) * 110)
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
        totalsMark = nil
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
            totalsMark = nil
            marksFading = false
        }
    }

    /// Refreshes when the app comes to the front, at most once every two minutes.
    func refreshOnOpenIfNeeded() async {
        guard settings.refreshOnOpen, !needsOnboarding else { return }
        if let last = cache.lastRefresh, Date().timeIntervalSince(last) < 120 { return }
        await refreshAll()
    }

    // MARK: Reviews

    func reply(to review: Review, text: String) async throws {
        guard let project = projects.first(where: { $0.id == review.projectId }) else { return }
        try await provider.reply(to: review, text: text, in: project)
        if var list = cache.reviews[project.id], let index = list.firstIndex(where: { $0.id == review.id }) {
            list[index].reply = ReviewReply(text: text, date: Date(), pending: review.platform == .appStore)
            cache.reviews[project.id] = list
            cache.snapshots[project.id]?.reviewsToAnswer = list.filter(\.needsReply).count
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

    func save(project: Project) {
        if let index = workspace.projects.firstIndex(where: { $0.id == project.id }) {
            workspace.projects[index] = project
        } else {
            workspace.projects.append(project)
        }
        SharedContainer.workspace.save(workspace)
        SharedContainer.removeProjectIcons(project.id, keeping: project.iconVersion)
        WidgetCenter.shared.reloadAllTimelines()
    }

    func delete(project: Project) {
        workspace.projects.removeAll { $0.id == project.id }
        SharedContainer.removeProjectIcons(project.id)
        cache.snapshots[project.id] = nil
        cache.reviews[project.id] = nil
        SharedContainer.workspace.save(workspace)
        saveCache()
        WidgetCenter.shared.reloadAllTimelines()
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
            if project.revenueCat?.accountId == account.id {
                project.revenueCat = nil
                if project.metrics.revenue == .revenueCat { project.metrics.revenue = .none }
            }
            if project.appStore?.accountId == account.id { project.appStore = nil }
            if project.googlePlay?.accountId == account.id { project.googlePlay = nil }
            workspace.projects[index] = project
        }
        SharedContainer.workspace.save(workspace)
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
        if modeChanged { switchMode() }
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
        let provider = DemoProvider(world: SharedContainer.demoWorld.load(), persist: { SharedContainer.demoWorld.save($0) })
        demo = provider
        Task { await seedDemoIfEmpty(provider) }
    }

    /// Fills an empty demo cache with today's sample numbers so the first screen is never a row of dashes.
    private func seedDemoIfEmpty(_ provider: DemoProvider) async {
        guard settings.demoMode, cache.snapshots.isEmpty else { return }
        for result in await provider.seed() {
            cache.snapshots[result.snapshot.projectId] = result.snapshot
            if let reviews = result.reviews { cache.reviews[result.snapshot.projectId] = reviews }
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
