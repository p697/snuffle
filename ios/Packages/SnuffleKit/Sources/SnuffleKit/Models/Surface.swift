import Foundation

/// Where a PostHog event came from, told apart by the properties PostHog's SDKs set themselves, so no setup is
/// needed. One PostHog project often holds several: an app on two platforms, the website that markets it, a web
/// version people sign in to, a server or desktop client. People-based numbers (active, online, started using, page
/// views) count only the surfaces a project includes, so a website's passing visitors never inflate an app's actives.
public enum Surface: String, Codable, CaseIterable, Sendable, Identifiable {
    case ios
    case android
    /// The web, by people who signed in (posthog-js marks their events as identified).
    case web
    /// The web, by people who never signed in: mostly readers of a marketing site.
    case visitors
    /// Server SDKs, desktop clients and anything sent to the capture API without an SDK.
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ios: String(localized: "iOS App", bundle: .module)
        case .android: String(localized: "Android App", bundle: .module)
        case .web: String(localized: "网页（登录用户）", bundle: .module)
        case .visitors: String(localized: "网站访客（未登录）", bundle: .module)
        case .other: String(localized: "其他来源", bundle: .module)
        }
    }

    public var detail: String {
        switch self {
        case .ios: String(localized: "iPhone 和 iPad 上的 App", bundle: .module)
        case .android: String(localized: "Android 手机和平板上的 App", bundle: .module)
        case .web: String(localized: "在网站或网页版里登录过的人", bundle: .module)
        case .visitors: String(localized: "没登录就离开的网站访客，多半是来看官网的人", bundle: .module)
        case .other: String(localized: "服务端、桌面端，或直接用接口上报的事件", bundle: .module)
        }
    }

    /// The surfaces a project leaves out until the person chooses: website visitors when the product also has people
    /// who sign in or use an app, so a marketing site's readers never count as users. A website without sign-in keeps
    /// them, even when a server sends a few events of its own (`other`).
    public static func defaultExcluded(seen: some Collection<Surface>) -> Set<Surface> {
        seen.contains { $0 == .web || $0 == .ios || $0 == .android } ? [.visitors] : []
    }
}

/// How many people a surface had in the last 30 days, for choosing what to count.
public struct SurfaceStat: Hashable, Sendable, Identifiable {
    public var surface: Surface
    public var people: Int

    public var id: Surface { surface }

    public init(surface: Surface, people: Int) {
        self.surface = surface
        self.people = people
    }
}
