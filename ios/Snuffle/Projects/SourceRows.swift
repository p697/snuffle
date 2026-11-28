import SnuffleKit
import SwiftUI

/// The four sources a project can read, as four tiles: the connected ones in colour with a tick, the missing ones faded
/// with a plus. The shape says what words would have to: a project holds all four, and more can be added here.
struct SourceSlots: View {
    var project: Project
    /// Sources that did not answer in the last refresh, marked instead of ticked.
    var failed: Set<Platform> = []
    /// A connected tile; nil leaves it as a picture.
    var open: ((Platform) -> Void)?
    /// A missing tile; nil leaves it as a picture (demo projects cannot change).
    var connect: ((Platform) -> Void)?
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Platform.allCases) { platform in
                tile(platform)
            }
        }
    }

    @ViewBuilder
    private func tile(_ platform: Platform) -> some View {
        let connected = project.platforms.contains(platform)
        // A tile with nothing to do is a picture, not a disabled button, so it keeps its colour.
        if let action = connected ? open.map({ open in { open(platform) } }) : connect.map({ connect in { connect(platform) } }) {
            Button(action: action) { face(platform, connected: connected) }
                .buttonStyle(.plain)
                .accessibilityLabel(connected ? String(localized: "\(platform.displayName) 已连接") : String(localized: "接上 \(platform.displayName)"))
                .accessibilityIdentifier(connected ? "source-\(platform.rawValue)" : "addSource-\(platform.rawValue)")
        } else {
            face(platform, connected: connected)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(connected ? Text("\(platform.displayName) 已连接") : Text(verbatim: platform.displayName))
        }
    }

    private func face(_ platform: Platform, connected: Bool) -> some View {
        VStack(spacing: 8) {
            PlatformLogo(platform: platform, size: 40)
                .saturation(connected ? 1 : 0)
                .opacity(connected ? 1 : 0.4)
                .overlay(alignment: .topTrailing) { badge(platform, connected: connected).offset(x: 7, y: -7) }
            Text(platform.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(connected ? Palette.ink : Palette.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func badge(_ platform: Platform, connected: Bool) -> some View {
        let symbol = !connected ? "plus" : failed.contains(platform) ? "exclamationmark" : "checkmark"
        let fill = !connected ? accent : failed.contains(platform) ? Palette.warn : Palette.up
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .black))
            .foregroundStyle(connected ? Color.white : Palette.onAccent)
            .frame(width: 18, height: 18)
            .background(fill, in: Circle())
            .overlay(Circle().strokeBorder(Palette.card, lineWidth: 2))
    }
}

/// A project's sources as rows in its settings: what each connected one reads with a way to disconnect it, and the
/// missing ones with a way to connect them.
struct SourceRows: View {
    var project: Project
    var connect: (Platform) -> Void
    var disconnect: (Platform) -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        CardGroup {
            ForEach(Array(Platform.allCases.enumerated()), id: \.element) { index, platform in
                if index > 0 { RowDivider() }
                row(platform)
            }
        }
    }

    private func row(_ platform: Platform) -> some View {
        let linked = project.linkName(platform)
        return HStack(spacing: 12) {
            PlatformLogo(platform: platform, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(platform.displayName).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
                if let linked {
                    Text(verbatim: linked).font(.system(size: 12)).foregroundStyle(Palette.ink2).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if linked != nil {
                Button("断开") { disconnect(platform) }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.bad)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .overlay(Capsule().strokeBorder(Palette.line))
                    .frame(minHeight: 44)
            } else {
                Button("接上") { connect(platform) }
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Palette.onAccent)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 34)
                    .background(accent, in: Capsule())
                    .frame(minHeight: 44)
                    .accessibilityLabel(String(localized: "接上 \(platform.displayName)"))
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
    }
}

extension Project {
    /// What this project reads on a platform, by name; nil when it is not connected.
    func linkName(_ platform: Platform) -> String? {
        switch platform {
        case .posthog: posthog?.projectName
        case .revenueCat: revenueCat?.projectName
        case .appStore: appStore?.appName
        case .googlePlay: googlePlay?.packageName
        }
    }
}
