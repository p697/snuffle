import Foundation

/// The four places Snuffle reads numbers and reviews from.
public enum Platform: String, Codable, CaseIterable, Sendable, Identifiable {
    case posthog
    case revenueCat
    case appStore
    case googlePlay

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .posthog: "PostHog"
        case .revenueCat: "RevenueCat"
        case .appStore: "App Store"
        case .googlePlay: "Google Play"
        }
    }
}

/// A product the person runs. Each platform link is optional; a project needs at least PostHog or a store to show anything.
public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var tint: ProjectTint
    public var includeInRefresh: Bool
    public var posthog: PostHogLink?
    public var revenueCat: RevenueCatLink?
    public var appStore: AppStoreLink?
    public var googlePlay: GooglePlayLink?
    public var metrics: MetricSettings

    public init(
        id: UUID = UUID(),
        name: String,
        tint: ProjectTint,
        includeInRefresh: Bool = true,
        posthog: PostHogLink? = nil,
        revenueCat: RevenueCatLink? = nil,
        appStore: AppStoreLink? = nil,
        googlePlay: GooglePlayLink? = nil,
        metrics: MetricSettings = .standard
    ) {
        self.id = id
        self.name = name
        self.tint = tint
        self.includeInRefresh = includeInRefresh
        self.posthog = posthog
        self.revenueCat = revenueCat
        self.appStore = appStore
        self.googlePlay = googlePlay
        self.metrics = metrics
    }

    /// The letter on the project's square badge.
    public var monogram: String { name.first.map { String($0).uppercased() } ?? "?" }

    /// Platforms this project reads from, in the order they are fetched.
    public var platforms: [Platform] {
        var list: [Platform] = []
        if posthog != nil { list.append(.posthog) }
        if revenueCat != nil { list.append(.revenueCat) }
        if appStore != nil { list.append(.appStore) }
        if googlePlay != nil { list.append(.googlePlay) }
        return list
    }

    /// Every account this project depends on, so removing an account can tell which projects it breaks.
    public var accountIds: Set<UUID> {
        Set([posthog?.accountId, revenueCat?.accountId, appStore?.accountId, googlePlay?.accountId].compactMap { $0 })
    }

    public var hasStore: Bool { appStore != nil || googlePlay != nil }
}

/// Badge colours. Stored by name so a palette change never rewrites saved projects.
public enum ProjectTint: String, Codable, CaseIterable, Sendable {
    case ink, coral, cocoa, ocean, moss, plum
}

public struct PostHogLink: Codable, Hashable, Sendable {
    public var accountId: UUID
    public var projectId: Int
    public var projectName: String
    /// IANA identifier from the PostHog project; "today" starts at midnight here.
    public var timeZone: String

    public init(accountId: UUID, projectId: Int, projectName: String, timeZone: String) {
        self.accountId = accountId
        self.projectId = projectId
        self.projectName = projectName
        self.timeZone = timeZone
    }
}

public struct RevenueCatLink: Codable, Hashable, Sendable {
    public var accountId: UUID
    public var projectId: String
    public var projectName: String

    public init(accountId: UUID, projectId: String, projectName: String) {
        self.accountId = accountId
        self.projectId = projectId
        self.projectName = projectName
    }
}

public struct AppStoreLink: Codable, Hashable, Sendable {
    public var accountId: UUID
    public var appId: String
    public var appName: String
    public var bundleId: String

    public init(accountId: UUID, appId: String, appName: String, bundleId: String) {
        self.accountId = accountId
        self.appId = appId
        self.appName = appName
        self.bundleId = bundleId
    }
}

public struct GooglePlayLink: Codable, Hashable, Sendable {
    public var accountId: UUID
    public var packageName: String

    public init(accountId: UUID, packageName: String) {
        self.accountId = accountId
        self.packageName = packageName
    }
}

/// How a project's headline numbers are counted. Chosen when the project is added and editable later.
public struct MetricSettings: Codable, Hashable, Sendable {
    public enum NewUsers: Codable, Hashable, Sendable {
        /// Count this PostHog event, e.g. `user_signed_up`.
        case event(String)
        /// Count people PostHog saw for the first time.
        case firstSeen
    }

    public enum Revenue: Codable, Hashable, Sendable {
        /// Sum a numeric property of a PostHog event, e.g. `purchase` / `value`.
        case posthogEvent(event: String, valueProperty: String)
        /// RevenueCat's own daily revenue total.
        case revenueCat
        case none
    }

    /// The second small number on the card.
    public enum Extra: Codable, Hashable, Sendable {
        /// PostHog's `Application Installed` event (`MetricSettings.installEvent`).
        case installs
        /// Any event, shown as "<count> <label>", e.g. "25 次付费墙浏览".
        case event(name: String, label: String)
        case none
    }

    public var newUsers: NewUsers
    public var revenue: Revenue
    public var extra: Extra

    public init(newUsers: NewUsers, revenue: Revenue, extra: Extra) {
        self.newUsers = newUsers
        self.revenue = revenue
        self.extra = extra
    }

    /// PostHog's conventional signup event and the install event its mobile SDKs send.
    public static let signupEvent = "user_signed_up"
    public static let installEvent = "Application Installed"

    public static let standard = MetricSettings(newUsers: .event(signupEvent), revenue: .none, extra: .installs)

    /// Defaults for a project, given which of the conventional events it actually sends: a project without signups
    /// counts first-seen people, and one without installs shows no second number, so nothing sits at zero forever.
    public static func suggested(seenEvents: Set<String>) -> MetricSettings {
        MetricSettings(
            newUsers: seenEvents.contains(signupEvent) ? .event(signupEvent) : .firstSeen,
            revenue: .none,
            extra: seenEvents.contains(installEvent) ? .installs : .none
        )
    }
}
