import SnuffleKit
import SwiftUI

/// The project being connected, shared by every page of one connect flow, plus what each platform returned so a
/// later page (the picker, the "项目建好了" summary) does not ask again.
@MainActor
@Observable
final class ConnectSession {
    var project: Project
    /// The saved project as it was before this flow, for one more source; nil when adding a project.
    let original: Project?
    var isNewProject: Bool { original == nil }
    var postHogAccount: Account?
    var postHogProjects: [PostHogProject] = []
    /// The chosen PostHog project's dashboards; nil when they could not be read.
    var postHogDashboards: [DashboardSummary]?
    var revenueCatProjects: [RevenueCatProject] = []
    var appStoreApps: [AppStoreApp] = []
    var googleApps: [GooglePlayApp] = []

    init(project: Project, isNewProject: Bool) {
        self.project = project
        original = isNewProject ? nil : project
    }

    /// Records one attempt to sign in to or verify a platform account.
    func track(_ platform: Platform, _ method: Analytics.ConnectMethod, _ outcome: Analytics.ConnectOutcome) {
        Analytics.sourceConnectResolved(platform, method: method, newProject: isNewProject, outcome: outcome)
    }

    /// The project as it will be saved. Its card follows the sources connected so far, unless the person already
    /// changed the card of a saved project.
    var finished: Project {
        var finished = project
        if original.map({ $0.card == CardLayout.standard(for: $0) }) ?? true {
            finished.card = CardLayout.standard(for: finished)
        }
        return finished
    }

    /// A copy of the project reading only `platform`, to show what that one source returns right after connecting.
    func probe(_ platform: Platform) -> Project {
        var copy = project
        if platform != .posthog { copy.posthog = nil }
        if platform != .revenueCat { copy.revenueCat = nil }
        if platform != .appStore { copy.appStore = nil }
        if platform != .googlePlay { copy.googlePlay = nil }
        return copy
    }

    /// Names the product is known by so far, to find the same product on the next platform.
    var knownNames: [String] { project.knownNames }

    /// The candidate that is obviously this product: the one whose name matches a known name, or the only one when
    /// nothing is known yet. A lone candidate that matches nothing is asked about, so a key or account that only
    /// sees another product (a RevenueCat key belongs to one project) never links that product silently.
    func obvious<Item>(_ items: [Item], names: (Item) -> [String]) -> Item? {
        let known = knownNames.map(Project.comparable).filter { !$0.isEmpty }
        if known.isEmpty { return items.count == 1 ? items[0] : nil }
        let matches = items.filter { item in
            names(item).map(Project.comparable).filter { !$0.isEmpty }.contains { name in
                known.contains { name.contains($0) || $0.contains(name) }
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Names a new project after a store listing, without its tagline.
    func name(fromStore listing: String) {
        if project.name.isEmpty { project.name = Project.shortName(listing) }
    }

    /// Uses the App Store icon as the project's picture when it has none. Without a URL at hand (an app listed by a
    /// key) the app is looked up by its id in the phone's storefront, then the US one.
    func adoptIcon(_ url: URL?, appId: String) async {
        guard project.iconVersion == nil else { return }
        var found = url
        if found == nil {
            for country in [Locale.current.region?.identifier.lowercased(), "us"].compactMap({ $0 }) {
                if let icon = try? await PublicAppStoreClient().lookup(appId: appId, country: country)?.icon {
                    found = icon
                    break
                }
            }
        }
        guard let found, let (data, _) = try? await URLSession.shared.data(from: found), let image = UIImage(data: data),
              project.iconVersion == nil, let version = try? ProjectIcons.save(image, for: project) else { return }
        project.iconVersion = version
    }

    /// A new project that is not kept leaves no picture behind.
    func discard() {
        if isNewProject { SharedContainer.removeProjectIcons(project.id) }
    }
}
