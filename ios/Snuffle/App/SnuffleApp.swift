import SnuffleKit
import SwiftUI

@main
struct SnuffleApp: App {
    @State private var model: AppModel

    init() {
        Analytics.start()
        let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String
        let group = prefix.map { $0 + SharedContainer.keychainGroupSuffix }
        _model = State(initialValue: AppModel(
            credentials: KeychainCredentialStore(accessGroup: group),
            pro: ProStore(),
            cloud: CloudClient()
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(\.accent, model.settings.accent.color)
                .preferredColorScheme(model.settings.theme.colorScheme)
                .tint(Palette.ink)
        }
    }
}

extension AppSettings.Theme {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
