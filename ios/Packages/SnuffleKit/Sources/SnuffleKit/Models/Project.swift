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
    /// The numbers on the project's card.
    public var card: CardLayout
    /// Charts from the project's PostHog dashboards placed on its board, in order.
    public var pins: [InsightTile]
    /// Whether its PostHog dashboards were looked at for a counting to follow, once (when it was added, or the first
    /// refresh after an update, as soon as the dashboards could be read).
    public var dashboardChecked: Bool
    /// Set when the person picked a picture for the project; bumped on every change. The picture lives only on this
    /// phone (`SharedContainer.projectIcon`), so it is lost with the app, like the rest of the local data.
    public var iconVersion: Int?

    public init(
        id: UUID = UUID(),
        name: String,
        tint: ProjectTint,
        includeInRefresh: Bool = true,
        posthog: PostHogLink? = nil,
        revenueCat: RevenueCatLink? = nil,
        appStore: AppStoreLink? = nil,
        googlePlay: GooglePlayLink? = nil,
        metrics: MetricSettings = .standard,
        card: CardLayout? = nil,
        pins: [InsightTile] = [],
        dashboardChecked: Bool = false,
        iconVersion: Int? = nil
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
        self.iconVersion = iconVersion
        self.pins = pins
        self.dashboardChecked = dashboardChecked
        self.card = CardLayout(big: [])
        self.card = card ?? CardLayout.standard(for: self)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        tint = try container.decode(ProjectTint.self, forKey: .tint)
        includeInRefresh = try container.decode(Bool.self, forKey: .includeInRefresh)
        posthog = try container.decodeIfPresent(PostHogLink.self, forKey: .posthog)
        revenueCat = try container.decodeIfPresent(RevenueCatLink.self, forKey: .revenueCat)
        appStore = try container.decodeIfPresent(AppStoreLink.self, forKey: .appStore)
        googlePlay = try container.decodeIfPresent(GooglePlayLink.self, forKey: .googlePlay)
        metrics = try container.decode(MetricSettings.self, forKey: .metrics)
        iconVersion = try container.decodeIfPresent(Int.self, forKey: .iconVersion)
        pins = try container.decodeIfPresent([InsightTile].self, forKey: .pins) ?? []
        dashboardChecked = try container.decodeIfPresent(Bool.self, forKey: .dashboardChecked) ?? false
        card = CardLayout(big: [])
        // Cards from before the dashboard redesign (TestFlight builds before November 26, 2026) start over with the
        // standard card, which shows the numbers the redesign is about. Remove once those builds are out of use.
        if let saved = try container.decodeIfPresent(CardLayout.self, forKey: .card),
           (try container.decodeIfPresent(CardLayout.Version.self, forKey: .card))?.v == CardLayout.version {
            card = saved
        } else {
            card = CardLayout.standard(for: self)
        }
    }

    /// The letter on the project's square badge.
    public var monogram: String { name.first.map { String($0).uppercased() } ?? "?" }

    /// A store listing's name without the tagline stores encourage: "Isaac Codex: TBOI Guide & Wiki" → "Isaac Codex".
    /// A name whose part before the separator is too short to stand alone is kept whole.
    public static func shortName(_ listing: String) -> String {
        let name = listing.trimmingCharacters(in: .whitespaces)
        let separators = [": ", "：", " - ", " – ", " — ", " | ", "｜"]
        let cut = separators.compactMap { name.range(of: $0)?.lowerBound }.min()
        guard let cut else { return name }
        let head = name[..<cut].trimmingCharacters(in: .whitespaces)
        return head.count >= 3 ? head : name
    }

    /// Letters and digits only, lowercased, so "Isaac Codex" matches "com.example.isaaccodex".
    public static func comparable(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Every name the product goes by on its sources, to recognise it elsewhere.
    public var knownNames: [String] {
        [name, posthog?.projectName, revenueCat?.projectName, appStore?.appName, googlePlay?.packageName]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

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

    /// Whether a store tells this project which reviews wait for a reply: the App Store only with a key.
    public var answersReviews: Bool { appStore?.hasKey == true || googlePlay != nil }

    /// Disconnects a platform. Revenue counted by RevenueCat stops being counted rather than counting nothing.
    public mutating func unlink(_ platform: Platform) {
        switch platform {
        case .posthog:
            posthog = nil
            pins = []
        case .revenueCat:
            revenueCat = nil
            if metrics.revenue == .revenueCat { metrics.revenue = .none }
        case .appStore: appStore = nil
        case .googlePlay: googlePlay = nil
        }
    }

    /// This project with the sources of another one it does not read yet: a second project started for the same
    /// product, put together. PostHog brings how people are counted and its dashboard charts; RevenueCat counts
    /// revenue unless revenue was already counted. Name, colour and picture stay this project's, and its card follows
    /// the new sources unless the person changed it.
    public func merging(_ other: Project) -> Project {
        var merged = self
        if merged.posthog == nil, let link = other.posthog {
            merged.posthog = link
            let revenue = merged.metrics.revenue
            merged.metrics = other.metrics
            if revenue != .none { merged.metrics.revenue = revenue }
            merged.pins = other.pins
            merged.dashboardChecked = other.dashboardChecked
        }
        if merged.revenueCat == nil, let link = other.revenueCat {
            merged.revenueCat = link
            if merged.metrics.revenue == .none { merged.metrics.revenue = .revenueCat }
        }
        if merged.appStore == nil { merged.appStore = other.appStore }
        if merged.googlePlay == nil { merged.googlePlay = other.googlePlay }
        if card == CardLayout.standard(for: self) { merged.card = CardLayout.standard(for: merged) }
        return merged
    }
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

/// An App Store app, read with an App Store Connect key (`accountId`: the newest reviews with their replies, and
/// replying) or without one (the public App Store's newest reviews in `countries`, which carry no replies).
public struct AppStoreLink: Codable, Hashable, Sendable {
    public var accountId: UUID?
    public var appId: String
    public var appName: String
    public var bundleId: String
    /// Storefronts (lowercase ISO 3166 alpha-2) the rating is read in, and without a key the reviews; at most
    /// `maxCountries`. Empty while the app is not on the public App Store, or for links from before ratings.
    public var countries: [String]

    /// Each country costs a request per refresh.
    public static let maxCountries = 5

    public init(accountId: UUID?, appId: String, appName: String, bundleId: String, countries: [String] = []) {
        self.accountId = accountId
        self.appId = appId
        self.appName = appName
        self.bundleId = bundleId
        self.countries = Array(countries.prefix(Self.maxCountries))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try container.decodeIfPresent(UUID.self, forKey: .accountId)
        appId = try container.decode(String.self, forKey: .appId)
        appName = try container.decode(String.self, forKey: .appName)
        bundleId = try container.decode(String.self, forKey: .bundleId)
        countries = try container.decodeIfPresent([String].self, forKey: .countries) ?? []
    }

    public var hasKey: Bool { accountId != nil }
}

public struct GooglePlayLink: Codable, Hashable, Sendable {
    public var accountId: UUID
    public var packageName: String

    public init(accountId: UUID, packageName: String) {
        self.accountId = accountId
        self.packageName = packageName
    }
}

/// How one person, or one installation, is counted in the people numbers.
public enum PeopleUnit: String, Codable, CaseIterable, Sendable {
    /// PostHog's person: everyone a sign-in merged is one, whatever devices they used.
    case person
    /// One `distinct_id`: an app installation or a browser, the way most app dashboards count installs.
    case install
}

/// The PostHog dashboard a project's counting was read from.
public struct DashboardRef: Codable, Hashable, Sendable {
    public var id: Int
    public var name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

/// How a project's numbers are counted: who counts as a user, and how new users and revenue are counted. Chosen when
/// the project is added (from its PostHog dashboards when it has them) and editable later.
public struct MetricSettings: Hashable, Sendable {
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

    public var newUsers: NewUsers
    public var revenue: Revenue
    /// Surfaces left out of the people numbers (`Metric.isScoped`). Nil until the project's events were seen once;
    /// the first refresh fills it with `Surface.defaultExcluded`.
    public var excludedSurfaces: Set<Surface>?
    /// The event that means someone used the product, e.g. `app_opened`; nil counts any event.
    public var activityEvent: String?
    /// HogQL conditions every people number keeps to, e.g. `properties.app_environment = 'release'`.
    public var conditions: [String]
    public var unit: PeopleUnit
    /// The event property that names the platform, e.g. `app_platform`; nil tells platforms apart the way PostHog's
    /// SDKs do (`Surface`).
    public var platformProperty: String?
    /// The first day the totals count from (a day start in the project's zone); nil counts all history.
    public var since: Date?
    /// The dashboard this counting was read from; its charts are where the numbers are checked.
    public var dashboard: DashboardRef?

    public init(
        newUsers: NewUsers,
        revenue: Revenue,
        excludedSurfaces: Set<Surface>? = nil,
        activityEvent: String? = nil,
        conditions: [String] = [],
        unit: PeopleUnit = .person,
        platformProperty: String? = nil,
        since: Date? = nil,
        dashboard: DashboardRef? = nil
    ) {
        self.newUsers = newUsers
        self.revenue = revenue
        self.excludedSurfaces = excludedSurfaces
        self.activityEvent = activityEvent
        self.conditions = conditions
        self.unit = unit
        self.platformProperty = platformProperty
        self.since = since
        self.dashboard = dashboard
    }

    /// What to leave out now: the person's choice, or website visitors while nothing was chosen or seen yet.
    public var surfacesLeftOut: Set<Surface> { excludedSurfaces ?? [.visitors] }

    /// These settings with the surfaces actually left out, as numbers are read under them.
    public var inEffect: MetricSettings { leaving(out: surfacesLeftOut) }

    public func leaving(out surfaces: Set<Surface>) -> MetricSettings {
        var settings = self
        settings.excludedSurfaces = surfaces
        return settings
    }

    /// Counted the way Snuffle does by itself: any event, people, every surface but website visitors.
    public var isStandardPeople: Bool {
        activityEvent == nil && conditions.isEmpty && unit == .person && platformProperty == nil && since == nil
    }

    /// PostHog's conventional signup event and the install event its mobile SDKs send.
    public static let signupEvent = "user_signed_up"
    public static let installEvent = "Application Installed"

    public static let standard = MetricSettings(newUsers: .event(signupEvent), revenue: .none)
}

extension MetricSettings: Codable {
    enum CodingKeys: String, CodingKey {
        case newUsers, revenue, excludedSurfaces, activityEvent, conditions, unit, platformProperty, since, dashboard
    }

    /// Settings saved before counting could follow a dashboard have none of its keys: they read as Snuffle's own.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        newUsers = try container.decode(NewUsers.self, forKey: .newUsers)
        revenue = try container.decode(Revenue.self, forKey: .revenue)
        excludedSurfaces = try container.decodeIfPresent(Set<Surface>.self, forKey: .excludedSurfaces)
        activityEvent = try container.decodeIfPresent(String.self, forKey: .activityEvent)
        conditions = try container.decodeIfPresent([String].self, forKey: .conditions) ?? []
        unit = (try? container.decodeIfPresent(PeopleUnit.self, forKey: .unit)) ?? .person
        platformProperty = try container.decodeIfPresent(String.self, forKey: .platformProperty)
        since = try container.decodeIfPresent(Date.self, forKey: .since)
        dashboard = try container.decodeIfPresent(DashboardRef.self, forKey: .dashboard)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(newUsers, forKey: .newUsers)
        try container.encode(revenue, forKey: .revenue)
        try container.encodeIfPresent(excludedSurfaces, forKey: .excludedSurfaces)
        try container.encodeIfPresent(activityEvent, forKey: .activityEvent)
        if !conditions.isEmpty { try container.encode(conditions, forKey: .conditions) }
        if unit != .person { try container.encode(unit, forKey: .unit) }
        try container.encodeIfPresent(platformProperty, forKey: .platformProperty)
        try container.encodeIfPresent(since, forKey: .since)
        try container.encodeIfPresent(dashboard, forKey: .dashboard)
    }
}

extension Project {
    /// Counting defaults from the events the project actually sends: without signups new users are first-seen
    /// people, so nothing sits at zero forever.
    public mutating func adoptDefaults(seenEvents: Set<String>) {
        metrics.newUsers = seenEvents.contains(MetricSettings.signupEvent) ? .event(MetricSettings.signupEvent) : .firstSeen
        card = CardLayout.standard(for: self)
    }
}
