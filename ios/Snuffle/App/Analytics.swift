import Foundation
import PostHog
import SnuffleKit
import WidgetKit

/// Anonymous product analytics in PostHog: the only place the app talks to the SDK. The catalog, metric definitions
/// and rules are in `ios/ANALYTICS.md`; change them together with these methods.
///
/// Payloads are small enums, booleans and counts. Never names, emails, keys, ids, numbers read from a source,
/// review text or error messages. Identity is the SDK's anonymous install id; `identify` is never called.
@MainActor
enum Analytics {
    static let schemaVersion = 1
    private static var started = false

    /// Starts the SDK unless there is no project token (forks, local builds) or this is a test run.
    static func start() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard !started,
              let token = info["SnufflePostHogToken"] as? String, token.hasPrefix("phc_"),
              let host = info["SnufflePostHogHost"] as? String, !host.isEmpty,
              !isTestRun else { return }
        let config = PostHogConfig(projectToken: token, host: host)
        // Only the events below: no automatic lifecycle, screen, element or replay capture, no feature flags.
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.enableSwizzling = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        config.personProfiles = .never
        config.setDefaultPersonProperties = false
        PostHogSDK.shared.setup(config)
        PostHogSDK.shared.register(baseProperties)
        started = true
    }

    /// Unit tests host the app; UI tests pass `-noAnalytics`. Neither may reach the live project.
    private static var isTestRun: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.arguments.contains("-noAnalytics")
    }

    static var baseProperties: [String: Any] {
        ["client_app": "snuffle_ios", "analytics_schema_version": schemaVersion, "app_environment": environment]
    }

    /// `development` for Debug builds and anything signed with a provisioning profile (the owner's own device
    /// builds); `release` for TestFlight and the App Store, which the SDK's `$is_testflight` tells apart.
    private static var environment: String {
        #if DEBUG
        return "development"
        #else
        return Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") == nil ? "release" : "development"
        #endif
    }

    /// Who this install is right now, sent with every later event.
    static func setWorkspace(demoMode: Bool, projectCount: Int) {
        register(["demo_mode": demoMode, "project_count": projectCount])
    }

    static func setPro(_ isPro: Bool) {
        register(["is_pro": isPro])
    }

    private static func registerWidgetCount() async {
        guard started, let widgets = try? await WidgetCenter.shared.currentConfigurations() else { return }
        register(["widget_count": widgets.count])
    }

    private static func register(_ properties: [String: Any]) {
        guard started else { return }
        PostHogSDK.shared.register(properties)
    }

    static func capture(_ event: String, _ properties: [String: Any] = [:]) {
        guard started else { return }
        PostHogSDK.shared.capture(event, properties: properties)
    }

    // MARK: Catalog

    /// The app came to the front. Active installs and retention count this event.
    static func appOpened() {
        Task {
            await registerWidgetCount()
            capture("app_opened")
        }
    }

    static func tabViewed(_ tab: Tab) {
        capture("tab_viewed", ["tab": tab.analyticsName])
    }

    static func demoModeChanged(enabled: Bool) {
        capture("demo_mode_changed", ["enabled": enabled])
    }

    enum AddProjectSource: String {
        case welcome, home, projects
        /// An App Store Connect key file opened in Snuffle.
        case keyFile = "key_file"
    }

    static func addProjectOpened(_ source: AddProjectSource) {
        capture("add_project_opened", ["source": source.rawValue])
    }

    enum ConnectMethod: String {
        case oauth, key
        /// The App Store without a key: an app found by search.
        case search
        /// An account already on this phone.
        case saved
    }

    enum ConnectOutcome {
        case succeeded, cancelled
        case failed(Error)
    }

    /// One attempt to sign in to or verify a platform account: a tap that reached the platform, and how it ended.
    static func sourceConnectResolved(_ platform: Platform, method: ConnectMethod, newProject: Bool, outcome: ConnectOutcome) {
        var properties: [String: Any] = [
            "platform": platform.analyticsName,
            "method": method.rawValue,
            "flow": newProject ? "new_project" : "existing_project",
        ]
        switch outcome {
        case .succeeded: properties["outcome"] = "succeeded"
        case .cancelled: properties["outcome"] = "cancelled"
        case .failed(let error):
            properties["outcome"] = "failed"
            properties["error_kind"] = FailureKind(error).rawValue
        }
        capture("source_connect_resolved", properties)
    }

    static func projectSaved(_ project: Project, isNew: Bool, projectCount: Int) {
        capture("project_saved", [
            "is_new": isNew,
            "source_count": project.sourceCount,
            "has_posthog": project.posthog != nil,
            "has_revenuecat": project.revenueCat != nil,
            "has_app_store": project.appStore != nil,
            "has_google_play": project.googlePlay != nil,
            "project_count": projectCount,
            // Which kinds of traffic the project leaves out of its people numbers: surface kinds, never counts.
            "excluded_surfaces": project.posthog == nil ? [] : project.metrics.surfacesLeftOut.map(\.rawValue).sorted(),
        ])
    }

    /// The card editor's "完成". Event metrics are named "event", never by the event the person picked. `dragged`:
    /// whether a number was moved by dragging.
    static func cardLayoutSaved(_ layout: CardLayout, everywhere: Bool, dragged: Bool) {
        capture("card_layout_saved", [
            "big": layout.big.map(\.analyticsName),
            "small": layout.small.map(\.analyticsName),
            "rows": layout.rows.map(\.count),
            "dragged": dragged,
            "trend": layout.trend,
            "split": layout.split,
            "everywhere": everywhere,
        ])
    }

    /// Where a project's counting came from: its PostHog dashboard, the person's own edits, or Snuffle's standard.
    enum CountingSource: String {
        case dashboard, manual, standard
    }

    /// The shape of the counting only: whether it has an event, how many conditions, the unit. Never the event, the
    /// conditions or the dashboard themselves.
    static func countingChanged(_ source: CountingSource, settings: MetricSettings) {
        capture("counting_changed", [
            "source": source.rawValue,
            "has_activity_event": settings.activityEvent != nil,
            "condition_count": settings.conditions.count,
            "unit": settings.unit.rawValue,
            "has_platform_property": settings.platformProperty != nil,
            "has_since": settings.since != nil,
        ])
    }

    enum DashboardImportEntry: String {
        /// The step after choosing a PostHog project, adding a project or connecting PostHog to one.
        case connect
        /// The note on a project's page offering its dashboards.
        case offer
        /// The project page's menu.
        case menu
        /// "管理" above the charts already placed.
        case charts
    }

    /// The dashboard step or sheet ends: imported (charts placed and/or counting followed) or skipped. Counts only,
    /// never the dashboard or chart names.
    static func dashboardImportResolved(_ entry: DashboardImportEntry, imported: Bool, charts: Int, followsCounting: Bool) {
        capture("dashboard_import_resolved", [
            "entry": entry.rawValue,
            "outcome": imported ? "imported" : "skipped",
            "charts": charts,
            "follows_counting": followsCounting,
        ])
    }

    static func projectDeleted(_ project: Project, projectCount: Int) {
        capture("project_deleted", ["source_count": project.sourceCount, "project_count": projectCount])
    }

    static func accountRemoved(_ platform: Platform) {
        capture("account_removed", ["platform": platform.analyticsName])
    }

    enum RefreshTrigger: String {
        /// The big button or pull to refresh.
        case manual
        /// Coming to the front with "打开 App 时自动刷新" on.
        case open
        /// One project: its editor after the numbers changed, or a source signed in to again.
        case project
        /// Right after a project was added.
        case connect
        /// 重试 on the note about failed sources, or on a source in a project's sources.
        case retry
    }

    static func refreshCompleted(trigger: RefreshTrigger, projects: Int, failedProjects: Int, wentUp: Bool, sale: Bool, duration: Duration) {
        capture("refresh_completed", [
            "trigger": trigger.rawValue,
            "projects": projects,
            "failed_projects": failedProjects,
            "went_up": wentUp,
            "sale": sale,
            "duration_ms": Int(duration / .milliseconds(1)),
        ])
    }

    /// One source that could not be read in a refresh; one event per failing source per refresh.
    static func refreshSourceFailed(_ failure: SourceFailure) {
        capture("refresh_source_failed", ["platform": failure.platform.analyticsName, "error_kind": (failure.kind ?? .other).rawValue])
    }

    static func paywallViewed(_ reason: PaywallReason) {
        capture("paywall_viewed", ["reason": reason.rawValue])
    }

    enum PurchaseOutcome: String { case purchased, pending, cancelled, failed }

    /// Client-observed result of a purchase sheet; revenue, renewals and refunds come from App Store Connect.
    static func purchaseResolved(productId: String, reason: PaywallReason, trial: Bool, outcome: PurchaseOutcome) {
        capture("purchase_resolved", [
            "plan": ProStore.planName(productId),
            "reason": reason.rawValue,
            "trial": trial,
            "outcome": outcome.rawValue,
        ])
    }

    enum RestoreSource: String { case paywall, settings }

    static func restoreResolved(_ source: RestoreSource, restored: Bool) {
        capture("restore_resolved", ["source": source.rawValue, "outcome": restored ? "restored" : "not_found"])
    }

    static func reviewReplyResolved(_ platform: Platform, error: Error?) {
        var properties: [String: Any] = ["platform": platform.analyticsName, "outcome": error == nil ? "succeeded" : "failed"]
        if let error { properties["error_kind"] = FailureKind(error).rawValue }
        capture("review_reply_resolved", properties)
    }
}

extension Platform {
    var analyticsName: String {
        switch self {
        case .posthog: "posthog"
        case .revenueCat: "revenuecat"
        case .appStore: "app_store"
        case .googlePlay: "google_play"
        }
    }
}

extension Tab {
    var analyticsName: String {
        switch self {
        case .today: "today"
        case .money: "money"
        case .reviews: "reviews"
        case .projects: "projects"
        }
    }
}

extension Project {
    var sourceCount: Int {
        [posthog != nil, revenueCat != nil, appStore != nil, googlePlay != nil].filter { $0 }.count
    }
}
