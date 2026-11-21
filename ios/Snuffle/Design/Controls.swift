import SnuffleKit
import SwiftUI

// Shared controls for the connect flow, project pages and settings, so they match the home screen instead of
// looking like system settings: paper background, white rounded cards, ink capsules and one accent.

extension Platform {
    /// What a project gets from this platform, in a few words.
    var purpose: String {
        switch self {
        case .posthog: String(localized: "新增用户、在线和付费事件")
        case .revenueCat: String(localized: "收入和订阅")
        case .appStore, .googlePlay: String(localized: "评论和回复")
        }
    }
}

/// The platform's official mark. Logos that are not a square icon sit on a white tile.
struct PlatformLogo: View {
    var platform: Platform
    var size: CGFloat = 36

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        Image(asset)
            .resizable()
            .scaledToFit()
            .frame(width: size * inset, height: size * inset)
            .frame(width: size, height: size)
            .background(isSquareIcon ? Color.clear : Color.white, in: shape)
            .overlay { if !isSquareIcon { shape.strokeBorder(Palette.line) } }
            .clipShape(shape)
            .accessibilityHidden(true)
    }

    private var asset: String {
        switch platform {
        case .posthog: "logo-posthog"
        case .revenueCat: "logo-revenuecat"
        case .appStore: "logo-appstore"
        case .googlePlay: "logo-googleplay"
        }
    }

    /// RevenueCat's and the App Store's marks are already rounded squares.
    private var isSquareIcon: Bool { platform == .revenueCat || platform == .appStore }

    private var inset: CGFloat {
        switch platform {
        case .posthog: 0.74
        case .googlePlay: 0.56
        case .revenueCat, .appStore: 1
        }
    }
}

/// A 44 pt round button on a white disc: close, back.
struct RoundIconButton: View {
    var systemName: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.ink)
                .frame(width: 44, height: 44)
                .background(Palette.card, in: Circle())
                .overlay(Circle().strokeBorder(Palette.line))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A back button for pages pushed inside a sheet, where the navigation bar is hidden.
struct BackButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        RoundIconButton(systemName: "chevron.backward", label: String(localized: "返回")) { dismiss() }
    }
}

/// Big page heading for the sheets: the same weight as the tab titles.
struct PageTitle: View {
    var title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Typeface.title(32))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

extension View {
    /// The paper page every sheet in the connect flow sits on, without the system navigation bar.
    func sheetPage() -> some View {
        background(Palette.paper.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
    }
}

/// A switch in the app's colours: an ink track with an accent knob when on.
struct InkToggleStyle: ToggleStyle {
    @Environment(\.accent) private var accent

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                configuration.label
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Capsule()
                    .fill(configuration.isOn ? Palette.ink : Palette.line)
                    .frame(width: 52, height: 32)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(configuration.isOn ? accent : Palette.card)
                            .padding(3)
                    }
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isOn)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? String(localized: "开") : String(localized: "关"))
    }
}

/// Two to four mutually exclusive choices on a pill track; the chosen one is ink.
struct ChoiceBar<Value: Hashable>: View {
    var options: [(value: Value, label: LocalizedStringKey)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let chosen = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 13, weight: chosen ? .bold : .semibold))
                        .foregroundStyle(chosen ? Palette.paper : Palette.ink2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(chosen ? Palette.ink : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Palette.pill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

/// A rule between rows inside a card.
struct RowDivider: View {
    var body: some View { Palette.line.frame(height: 1) }
}

/// The colour dots for a project's badge.
struct TintDots: View {
    @Binding var tint: ProjectTint

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ProjectTint.allCases, id: \.self) { item in
                Button {
                    tint = item
                } label: {
                    Circle()
                        .fill(item.color)
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(Palette.ink, lineWidth: tint == item ? 2.5 : 0).padding(-4))
                        .frame(width: 38, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(tint == item ? .isSelected : [])
            }
        }
    }
}

extension ProjectTint {
    var label: String {
        switch self {
        case .ink: String(localized: "墨黑")
        case .coral: String(localized: "珊瑚")
        case .cocoa: String(localized: "可可")
        case .ocean: String(localized: "海蓝")
        case .moss: String(localized: "苔绿")
        case .plum: String(localized: "梅紫")
        }
    }
}

/// A numbered instruction. `text` is Markdown, so `**bold**` marks what to look for on the other site.
struct NumberedStep: View {
    var number: Int
    var text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: "\(number)")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(Palette.paper)
                .frame(width: 26, height: 26)
                .background(Palette.ink, in: Circle())
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "密钥没问题" and friends: a green capsule with a tick.
struct SuccessBadge: View {
    var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy))
            Text(text).font(.system(size: 13, weight: .bold))
        }
        .foregroundStyle(Palette.up)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Palette.upSoft, in: Capsule())
    }
}

/// A pill-shaped link out to another site.
struct OutLink: View {
    var title: String
    var url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "arrow.up.forward").font(.system(size: 12, weight: .heavy))
            }
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(Palette.pill, in: Capsule())
        }
    }
}

/// Red error text under a form.
struct ErrorText: View {
    var text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Palette.bad)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }
}

func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
