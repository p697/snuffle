import SnuffleKit
import SwiftUI

enum Tab: Hashable {
    case today, money, reviews, projects
}

/// Four tabs and the big refresh button between them. Tabs stay alive when hidden so their scroll position and
/// navigation are kept.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = Tab.today
    @State private var paywall = Self.launchPaywall
    @State private var barHeight: CGFloat = 0

    /// Debug builds launched with `-paywall history` open on the paywall for that reason, so UI tests reach
    /// the entries demo mode leaves unlocked.
    private static var launchPaywall: PaywallReason? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "paywall").flatMap(PaywallReason.init(rawValue:))
        #else
        nil
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
        .environment(\.openPaywall) { paywall = $0 }
        .sheet(item: $paywall) { reason in PaywallView(reason: reason) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshOnOpenIfNeeded() } }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { Analytics.appOpened() }
        }
        .onChange(of: tab) { _, value in Analytics.tabViewed(value) }
        .task { await model.refreshOnOpenIfNeeded() }
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
            item(.today, "今日", "waveform.path.ecg")
            item(.money, "收入", "dollarsign.circle")
            Color.clear.frame(width: 104, height: 46)
            item(.reviews, "评论", "text.bubble", badge: model.totals.reviewsToAnswer)
            item(.projects, "项目", "square.grid.2x2")
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

    private func item(_ value: Tab, _ title: String, _ symbol: String, badge: Int = 0) -> some View {
        Button {
            tab = value
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: tab == value ? .bold : .regular))
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Circle().fill(Palette.bad).frame(width: 7, height: 7).offset(x: 4, y: -1)
                        }
                    }
                Text(title)
                    .font(.system(size: 11, weight: tab == value ? .bold : .medium))
            }
            .foregroundStyle(tab == value ? Palette.ink : Palette.ink2)
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == value ? .isSelected : [])
        .accessibilityIdentifier("tab-\(title)")
    }
}

enum PaywallReason: String, Identifiable {
    case projects, history, drafts, widgets, general
    var id: String { rawValue }
}

extension EnvironmentValues {
    @Entry var openPaywall: (PaywallReason) -> Void = { _ in }
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
