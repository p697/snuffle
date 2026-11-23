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
        self.card = CardLayout(big: [])
        self.card = card ?? CardLayout.standard(for: self)
    }

    /// Reads projects saved before cards were customizable (TestFlight builds before November 23, 2026), which had a fixed big
    /// number and a "second number" in `metrics.extra`. Remove once those builds are out of use.
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
        card = CardLayout(big: [])
        if let saved = try container.decodeIfPresent(CardLayout.self, forKey: .card) {
            card = saved
        } else {
            // The old card: revenue, then the second number (PostHog only), then reviews.
            var small = CardLayout.standard(for: self, sendsInstalls: false).small
            if posthog != nil, let extra = (try? container.decode(LegacyMetrics.self, forKey: .metrics))?.extra?.metric {
                small.insert(extra, at: min(small.count, metrics.revenue == .none ? 0 : 1))
            }
            card = CardLayout(big: CardLayout.standard(for: self).big, small: small)
        }
    }

    private struct LegacyMetrics: Decodable {
        enum Extra: Decodable {
            case installs
            case event(name: String, label: String)
            case none

            var metric: Metric? {
                switch self {
                case .installs: .installs
                case .event(let name, _): name.isEmpty ? nil : .event(name, people: false)
                case .none: nil
                }
            }
        }
        var extra: Extra?
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

    /// Disconnects a platform. Revenue counted by RevenueCat stops being counted rather than counting nothing.
    public mutating func unlink(_ platform: Platform) {
        switch platform {
        case .posthog: posthog = nil
        case .revenueCat:
            revenueCat = nil
            if metrics.revenue == .revenueCat { metrics.revenue = .none }
        case .appStore: appStore = nil
        case .googlePlay: googlePlay = nil
        }
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

    public var newUsers: NewUsers
    public var revenue: Revenue

    public init(newUsers: NewUsers, revenue: Revenue) {
        self.newUsers = newUsers
        self.revenue = revenue
    }

    /// PostHog's conventional signup event and the install event its mobile SDKs send.
    public static let signupEvent = "user_signed_up"
    public static let installEvent = "Application Installed"

    public static let standard = MetricSettings(newUsers: .event(signupEvent), revenue: .none)
}

extension Project {
    /// Counting and card defaults from the events the project actually sends: without signups new users are
    /// first-seen people, and without installs the card has no install pill, so nothing sits at zero forever.
    public mutating func adoptDefaults(seenEvents: Set<String>) {
        metrics.newUsers = seenEvents.contains(MetricSettings.signupEvent) ? .event(MetricSettings.signupEvent) : .firstSeen
        card = CardLayout.standard(for: self, sendsInstalls: seenEvents.contains(MetricSettings.installEvent))
    }
}
