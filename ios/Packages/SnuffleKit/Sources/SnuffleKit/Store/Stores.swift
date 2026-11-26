import Foundation

/// The person's projects and connected accounts (no secrets).
public struct Workspace: Codable, Sendable, Equatable {
    public var projects: [Project]
    public var accounts: [Account]

    public init(projects: [Project] = [], accounts: [Account] = []) {
        self.projects = projects
        self.accounts = accounts
    }

    public func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }

    /// Projects that would lose a source if this account were removed.
    public func projects(using accountId: UUID) -> [Project] {
        projects.filter { $0.accountIds.contains(accountId) }
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public enum Theme: String, Codable, CaseIterable, Sendable { case system, light, dark }
    public enum Accent: String, Codable, CaseIterable, Sendable { case lemon, mint, peach, lilac }
    public enum ReplyTone: String, Codable, CaseIterable, Sendable { case warm, professional, brief }

    public var demoMode: Bool
    public var theme: Theme
    public var accent: Accent
    public var haptics: Bool
    public var sound: Bool
    public var refreshOnOpen: Bool
    public var replyTone: ReplyTone
    public var replySignature: String

    public init(
        demoMode: Bool = false,
        theme: Theme = .system,
        accent: Accent = .lemon,
        haptics: Bool = true,
        sound: Bool = false,
        refreshOnOpen: Bool = true,
        replyTone: ReplyTone = .warm,
        replySignature: String = ""
    ) {
        self.demoMode = demoMode
        self.theme = theme
        self.accent = accent
        self.haptics = haptics
        self.sound = sound
        self.refreshOnOpen = refreshOnOpen
        self.replyTone = replyTone
        self.replySignature = replySignature
    }

    enum CodingKeys: String, CodingKey {
        case demoMode, theme, accent, haptics, sound, refreshOnOpen, replyTone, replySignature
    }

    /// Every key is optional, so a setting added later never resets the others saved before it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let standard = AppSettings()
        demoMode = try container.decodeIfPresent(Bool.self, forKey: .demoMode) ?? standard.demoMode
        theme = (try? container.decodeIfPresent(Theme.self, forKey: .theme)) ?? standard.theme
        accent = (try? container.decodeIfPresent(Accent.self, forKey: .accent)) ?? standard.accent
        haptics = try container.decodeIfPresent(Bool.self, forKey: .haptics) ?? standard.haptics
        sound = try container.decodeIfPresent(Bool.self, forKey: .sound) ?? standard.sound
        refreshOnOpen = try container.decodeIfPresent(Bool.self, forKey: .refreshOnOpen) ?? standard.refreshOnOpen
        replyTone = (try? container.decodeIfPresent(ReplyTone.self, forKey: .replyTone)) ?? standard.replyTone
        replySignature = try container.decodeIfPresent(String.self, forKey: .replySignature) ?? standard.replySignature
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(demoMode, forKey: .demoMode)
        try container.encode(theme, forKey: .theme)
        try container.encode(accent, forKey: .accent)
        try container.encode(haptics, forKey: .haptics)
        try container.encode(sound, forKey: .sound)
        try container.encode(refreshOnOpen, forKey: .refreshOnOpen)
        try container.encode(replyTone, forKey: .replyTone)
        try container.encode(replySignature, forKey: .replySignature)
    }
}

/// The numbers a refresh reads for a project: its card, the four on its board and the widgets on screen. Anything
/// else costs a query nobody looks at.
public enum MetricsInUse {
    /// The board's four people numbers, read with the card so opening a project needs no wait.
    public static let board: [Metric] = [.totalUsers, .activeToday, .activeWeek, .newWeek]

    public static func forProject(_ project: Project, widgets: Set<Metric>) -> Set<Metric> {
        Set(project.card.metrics + board + widgets).filter { $0.isAvailable(in: project) }
    }
}

/// What the last refreshes produced, so the app opens with numbers already on screen and the widget can draw them.
public struct RefreshCache: Codable, Sendable, Equatable {
    public var snapshots: [UUID: ProjectSnapshot]
    public var reviews: [UUID: [Review]]
    public var refreshDay: Date?
    public var refreshCountToday: Int
    public var lastRefresh: Date?

    public init(snapshots: [UUID: ProjectSnapshot] = [:], reviews: [UUID: [Review]] = [:], refreshDay: Date? = nil, refreshCountToday: Int = 0, lastRefresh: Date? = nil) {
        self.snapshots = snapshots
        self.reviews = reviews
        self.refreshDay = refreshDay
        self.refreshCountToday = refreshCountToday
        self.lastRefresh = lastRefresh
    }

    /// Counts a finished refresh, starting the count over on a new local day.
    public mutating func recordRefresh(at date: Date, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: date)
        if refreshDay != day {
            refreshDay = day
            refreshCountToday = 0
        }
        refreshCountToday += 1
        lastRefresh = date
    }
}

/// Small JSON files in the shared app group container. Writes are atomic so the widget never reads half a file.
public struct FileStore<Value: Codable & Sendable>: Sendable {
    public var url: URL

    public init(directory: URL, name: String) {
        url = directory.appending(path: name)
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: [.atomic])
        } catch {
            assertionFailure("Could not save \(url.lastPathComponent): \(error)")
        }
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Where the app and the widget find each other's files and secrets.
public enum SharedContainer {
    public static let appGroup = "group.ai.snuffle.app"
    public static let keychainGroupSuffix = "ai.snuffle.shared"

    public static var directory: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? URL.applicationSupportDirectory.appending(path: "Snuffle")
    }

    public static var workspace: FileStore<Workspace> { FileStore(directory: directory, name: "workspace.json") }
    public static var settings: FileStore<AppSettings> { FileStore(directory: directory, name: "settings.json") }
    public static var liveCache: FileStore<RefreshCache> { FileStore(directory: directory, name: "cache-live.json") }
    public static var demoCache: FileStore<RefreshCache> { FileStore(directory: directory, name: "cache-demo.json") }
    public static var demoWorld: FileStore<DemoWorld> { FileStore(directory: directory, name: "demo-world.json") }

    /// Set by debug builds launched with `-storeShots`: the app and the widgets drop demo mode's "示例" marks, so
    /// App Store screenshots can use the made-up demo products. Release builds never set it.
    public static var hidesDemoMarks: Bool {
        get { UserDefaults(suiteName: appGroup)?.bool(forKey: "hidesDemoMarks") ?? false }
        set { UserDefaults(suiteName: appGroup)?.set(newValue, forKey: "hidesDemoMarks") }
    }

    /// The metrics placed widgets show, recorded by the widget each time it draws, so the app reads them too.
    /// Entries older than a day belong to widgets that were removed (a placed widget redraws at least hourly).
    public static func widgetMetrics(now: Date = .now) -> Set<Metric> {
        let seen = UserDefaults(suiteName: appGroup)?.dictionary(forKey: "widgetMetrics") as? [String: Date] ?? [:]
        return Set(seen.compactMap { id, date in now.timeIntervalSince(date) < 86_400 ? Metric(id: id) : nil })
    }

    public static func recordWidgetMetrics(_ metrics: [Metric], now: Date = .now) {
        let defaults = UserDefaults(suiteName: appGroup)
        var seen = (defaults?.dictionary(forKey: "widgetMetrics") as? [String: Date] ?? [:]).filter { now.timeIntervalSince($0.value) < 86_400 }
        for metric in metrics { seen[metric.id] = now }
        defaults?.set(seen, forKey: "widgetMetrics")
    }

    /// A project's picture. The version is in the name, so an edit that is cancelled never replaces the saved one.
    public static func projectIcon(_ projectId: UUID, version: Int) -> URL {
        directory.appending(path: "icons/\(projectId.uuidString)-\(version).jpg")
    }

    /// Deletes a project's pictures except `keep` (all of them when nil).
    public static func removeProjectIcons(_ projectId: UUID, keeping keep: Int? = nil) {
        let folder = directory.appending(path: "icons")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path())) ?? []
        for name in names where name.hasPrefix(projectId.uuidString + "-") && name != keep.map({ "\(projectId.uuidString)-\($0).jpg" }) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }
}
