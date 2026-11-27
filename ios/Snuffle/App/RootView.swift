import SnuffleKit
import SwiftUI

enum Tab: String, Hashable {
    case today, money, reviews, projects
}

/// Four tabs and the big refresh button between them. Tabs stay alive when hidden so their scroll position and
/// navigation are kept.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = Self.launchTab
    @State private var sheets = RootSheets(paywall: Self.launchPaywall)
    @State private var barHeight: CGFloat = 0
    /// A connect flow opened by a key file from Files or AirDrop.
    @State private var keyFlow = false

    /// Debug builds launched with `-paywall history` open on the paywall for that reason, so UI tests reach
    /// the entries demo mode leaves unlocked.
    private static var launchPaywall: PaywallReason? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "paywall").flatMap(PaywallReason.init(rawValue:))
        #else
        nil
        #endif
    }

    /// Debug builds launched with `-tab money` open on that tab, and with `-refreshAfterLaunch` press the refresh
    /// button two seconds in: `marketing/app-store/capture.sh` uses both to take the App Store screenshots.
    private static var launchTab: Tab {
        #if DEBUG
        UserDefaults.standard.string(forKey: "tab").flatMap(Tab.init(rawValue:)) ?? .today
        #else
        .today
        #endif
    }

    var body: some View {
        Group {
            if model.needsOnboarding {
                WelcomeView()
            } else {
                tabs
            }
        }
        .onOpenURL { url in
            guard url.isFileURL, let file = KeyFile(url: url) else { return }
            model.openedKeyFile = file
            // An open connect flow takes the file itself; otherwise start one on the App Store page.
            if model.openConnectFlows == 0 {
                keyFlow = true
                Analytics.addProjectOpened(.keyFile)
            }
        }
        .sheet(isPresented: $keyFlow) { AddProjectFlow(startsAt: .appStore) }
        .sheet(item: $sheets.paywall) { reason in PaywallView(reason: reason) }
        .sheet(item: $sheets.sources) { request in SourcesSheet(projectId: request.id) }
        .sheet(item: $sheets.signIn) { request in ReconnectSheet(project: request.project, platform: request.platform) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshOnOpenIfNeeded() } }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { Analytics.appOpened() }
        }
        .onChange(of: tab) { _, value in Analytics.tabViewed(value) }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-refreshAfterLaunch") {
                try? await Task.sleep(for: .seconds(2))
                await model.refreshAll()
                return
            }
            #endif
            await model.refreshOnOpenIfNeeded()
        }
        // Outermost, so the sheets presented here can read it too.
        .environment(sheets)
    }

    /// The bar floats over the pages. A bottom safe-area inset does not reach the scroll views inside each tab's
    /// NavigationStack, so every scrolling page adds the bar's measured height itself (`clearsTabBar()`).
    private var tabs: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                page(.today) { HomeView() }
                page(.money) { MoneyView() }
                page(.reviews) { ReviewsView() }
                page(.projects) { ProjectsView() }
            }
            .environment(\.tabBarClearance, barHeight)
            TabBar(tab: $tab)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                .ignoresSafeArea(.keyboard)
            // Clear of the cat's ears at rest; it only comes out further while a refresh runs.
            RefreshNoticeBar()
                .padding(.horizontal, 12)
                .padding(.bottom, barHeight + 16)
                .ignoresSafeArea(.keyboard)
        }
    }

    private func page(_ value: Tab, @ViewBuilder content: () -> some View) -> some View {
        content()
            .opacity(tab == value ? 1 : 0)
            .allowsHitTesting(tab == value)
            .accessibilityHidden(tab != value)
    }
}

private struct TabBar: View {
    @Binding var tab: Tab
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            item(.today, String(localized: "总览"), "waveform.path.ecg")
            item(.money, String(localized: "收入"), "dollarsign.circle")
            Color.clear.frame(width: 104, height: 46)
            item(.reviews, String(localized: "评论"), "text.bubble", dot: (model.total(.reviewsToAnswer) ?? 0) > 0 ? Palette.bad : nil)
            // Stays until the source is signed in to again, after the note about it is closed.
            item(.projects, String(localized: "项目"), "square.grid.2x2", dot: model.sourceProblem?.kind == .signIn ? Palette.warn : nil)
                .accessibilityValue(model.sourceProblem?.kind == .signIn ? Text("要重新登录") : Text(verbatim: ""))
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .background {
            Palette.card
                .overlay(alignment: .top) { Palette.line.frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            RefreshButton()
                .offset(y: -34)
        }
        // Room above the bar for the cat's head when it peeks out, so it never covers a card.
        .padding(.top, 26)
    }

    private func item(_ value: Tab, _ title: String, _ symbol: String, dot: Color? = nil) -> some View {
        Button {
            tab = value
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: tab == value ? .bold : .regular))
                    .overlay(alignment: .topTrailing) {
                        if let dot {
                            Circle().fill(dot).frame(width: 7, height: 7).offset(x: 4, y: -1)
                        }
                    }
                Text(title)
                    .font(.system(size: 11, weight: tab == value ? .bold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(tab == value ? Palette.ink : Palette.ink2)
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == value ? .isSelected : [])
        .accessibilityIdentifier("tab-\(String(describing: value))")
    }
}

/// The sheets any screen can open over the tabs. Screens ask through the environment (`@Environment(RootSheets.self)`)
/// and RootView presents them: a model rather than closures in the environment, which SwiftUI cannot compare and so
/// would redraw every reader on each update.
@MainActor
@Observable
final class RootSheets {
    var paywall: PaywallReason?
    /// A project's sources, opened from a number that stopped.
    var sources: SourcesRequest?
    /// Signing in to a source again, from the note about failed sources.
    var signIn: SignInRequest?

    init(paywall: PaywallReason? = nil) {
        self.paywall = paywall
    }

    func openPaywall(_ reason: PaywallReason) { paywall = reason }
    func openSources(_ projectId: UUID) { sources = SourcesRequest(id: projectId) }
    func openSignIn(to platform: Platform, of project: Project) { signIn = SignInRequest(project: project, platform: platform) }
}

struct SourcesRequest: Identifiable {
    var id: UUID
}

struct SignInRequest: Identifiable {
    var project: Project
    var platform: Platform
    var id: String { project.id.uuidString + platform.rawValue }
}

enum PaywallReason: String, Identifiable {
    case projects, history, drafts, widgets, general
    var id: String { rawValue }
}

extension EnvironmentValues {
    /// Height of the floating tab bar, including the room above it for the cat. Zero outside the tabs.
    @Entry var tabBarClearance: CGFloat = 0
}

extension View {
    /// For a tab's scroll view or list: its last row can scroll above the tab bar and the refresh button.
    func clearsTabBar() -> some View { modifier(TabBarClearance()) }
}

private struct TabBarClearance: ViewModifier {
    @Environment(\.tabBarClearance) private var clearance

    func body(content: Content) -> some View {
        content.contentMargins(.bottom, clearance, for: .scrollContent)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration, filled: filled)
    }

    /// A view, so it can read whether the button is enabled.
    private struct Label: View {
        var configuration: Configuration
        var filled: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(filled ? Palette.paper : Palette.ink)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(filled ? Palette.ink : Palette.card, in: Capsule())
                .overlay(Capsule().strokeBorder(filled ? .clear : Palette.line))
                .opacity(!isEnabled ? 0.35 : configuration.isPressed ? 0.8 : 1)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
        }
    }
}

/// A white rounded group, the building block of the detail and settings screens.
struct CardGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct SectionLabel: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Palette.ink2)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Large screen title used by every tab.
struct ScreenTitle: View {
    var title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Typeface.title(34)).foregroundStyle(Palette.ink)
            if let subtitle {
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Palette.ink2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}
