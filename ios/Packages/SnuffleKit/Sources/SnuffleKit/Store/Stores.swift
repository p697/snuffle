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
}
