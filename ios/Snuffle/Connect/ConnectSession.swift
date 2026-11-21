import SnuffleKit
import SwiftUI

/// The project being connected, shared by every page of one connect flow, plus what each platform returned so a
/// later page (the picker, the "连上了" summary) does not ask again.
@MainActor
@Observable
final class ConnectSession {
    var project: Project
    var postHogAccount: Account?
    var postHogProjects: [PostHogProject] = []
    var revenueCatProjects: [RevenueCatProject] = []
    var appStoreApps: [AppStoreApp] = []
    var googleApps: [GooglePlayApp] = []

    init(project: Project) {
        self.project = project
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
    var knownNames: [String] {
        [project.name, project.posthog?.projectName, project.revenueCat?.projectName, project.appStore?.appName, project.googlePlay?.packageName]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The candidate that is obviously this product: the only one, or the one whose name matches a known name.
    func obvious<Item>(_ items: [Item], names: (Item) -> [String]) -> Item? {
        if items.count == 1 { return items[0] }
        let known = knownNames.map { $0.lowercased() }
        guard !known.isEmpty else { return nil }
        let matches = items.filter { item in
            names(item).map { $0.lowercased() }.contains { name in known.contains { $0 == name || name.contains($0) || $0.contains(name) } }
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
