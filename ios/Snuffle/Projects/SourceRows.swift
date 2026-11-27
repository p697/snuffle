import SnuffleKit
import SwiftUI

/// A project's sources in one card: the connected ones first, with what each reads, then each missing one with what it
/// would add and a button to connect it right there. Used wherever a project is set up, so adding a source never
/// means finding another screen.
struct SourceRows: View {
    var project: Project
    /// The line under a connected source, and whether it is a problem; by default "已接上 · " and what it reads.
    var status: ((Platform) -> (text: String, warn: Bool)?)?
    /// Nil hides the missing sources (demo projects cannot change).
    var connect: ((Platform) -> Void)?
    var disconnect: ((Platform) -> Void)?
    @Environment(\.accent) private var accent

    init(project: Project, status: ((Platform) -> (text: String, warn: Bool)?)? = nil, connect: ((Platform) -> Void)?, disconnect: ((Platform) -> Void)? = nil) {
        self.project = project
        self.status = status
        self.connect = connect
        self.disconnect = disconnect
    }

    private var rows: [Platform] {
        let connected = project.platforms
        return connected + (connect == nil ? [] : Platform.allCases.filter { !connected.contains($0) })
    }

    var body: some View {
        CardGroup {
            ForEach(Array(rows.enumerated()), id: \.element) { index, platform in
                if index > 0 { RowDivider() }
                row(platform)
            }
        }
    }

    private func row(_ platform: Platform) -> some View {
        let linked = project.linkName(platform)
        let line = linked.flatMap { name in status?(platform) ?? (String(localized: "已接上 · \(name)"), false) }
        return HStack(spacing: 12) {
            PlatformLogo(platform: platform, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(platform.displayName).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
                if let line {
                    Text(line.text)
                        .font(.system(size: 12, weight: status == nil ? .semibold : .regular))
                        .foregroundStyle(line.warn ? Palette.warn : status == nil ? Palette.up : Palette.ink2)
                        .lineLimit(2)
                } else {
                    Text(platform.purpose).font(.system(size: 12)).foregroundStyle(Palette.ink2)
                }
            }
            Spacer(minLength: 8)
            if linked != nil {
                if let disconnect {
                    Button("断开") { disconnect(platform) }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.bad)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 34)
                        .overlay(Capsule().strokeBorder(Palette.line))
                        .frame(minHeight: 44)
                } else if line?.warn != true {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .heavy)).foregroundStyle(Palette.up)
                        .accessibilityLabel("已连上")
                }
            } else if let connect {
                Button("接上") { connect(platform) }
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Palette.onAccent)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 34)
                    .background(accent, in: Capsule())
                    .frame(minHeight: 44)
                    .accessibilityLabel(String(localized: "接上 \(platform.displayName)"))
                    .accessibilityIdentifier("addSource-\(platform.rawValue)")
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
