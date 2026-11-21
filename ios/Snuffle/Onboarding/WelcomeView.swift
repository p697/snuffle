import SnuffleKit
import SwiftUI

/// First launch: a poster of what one refresh brings, with the cat peeking over the panel that offers
/// connecting a product or looking at sample data.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var colorScheme
    @State private var adding = false
    @State private var cat = CatState()
    @State private var spinning = Array(repeating: false, count: Self.rows.count)

    private static let rows: [(value: String, label: String)] = [
        ("+48", "新用户"),
        ("+$300", "收入"),
        ("7", "条评论待回复")
    ]

    /// Room above the panel for the cat's head once it is out.
    private static let catHeadroom: CGFloat = 104

    private var colors: PosterColors { PosterColors(accent: accent, scheme: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 10)
            GeometryReader { geometry in
                poster(height: geometry.size.height)
            }
            .padding(.top, 22)
            .padding(.bottom, Self.catHeadroom)
            panel
        }
        .background(colors.fill.ignoresSafeArea())
        .sheet(isPresented: $adding) { AddProjectFlow() }
        .task { await play() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(colors.ink)
                .frame(width: 24, height: 24)
                .overlay(RefreshArrow().stroke(colors.fill, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)).frame(width: 14, height: 14))
                .accessibilityHidden(true)
            Text("Snuffle")
                .font(.system(size: 17, weight: .heavy))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Text("示例")
                .font(.system(size: 12, weight: .bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .overlay(Capsule().strokeBorder(colors.ink, lineWidth: 1.5))
                .accessibilityHidden(true)
        }
        .foregroundStyle(colors.ink)
        .frame(height: 28)
        .padding(.horizontal, 24)
    }

    /// Three ruled rows of giant numbers, as large as the screen allows (96 pt on a 6.1" phone).
    private func poster(height: CGFloat) -> some View {
        let size = min(96, max(44, (height - 2) / CGFloat(Self.rows.count) - 12))
        return VStack(spacing: 0) {
            ForEach(Self.rows.indices, id: \.self) { index in
                let row = Self.rows[index]
                VStack(spacing: 0) {
                    Rectangle().fill(colors.ink).frame(height: 2)
                    // First baseline: an odometer's last baseline is the bottom of its hidden digit strip.
                    HStack(alignment: .firstTextBaseline) {
                        Odometer(text: row.value, size: size, spinning: spinning[index], color: colors.ink)
                        Spacer(minLength: 12)
                        Text(row.label)
                            .font(.system(size: min(19, max(15, size * 0.2)), weight: .bold))
                            .foregroundStyle(colors.ink)
                            .lineLimit(1)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                }
            }
            Rectangle().fill(colors.ink).frame(height: 2)
        }
        .padding(.horizontal, 24)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("示例：新增 48 位用户，收入 300 美元，7 条评论待回复")
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("按一下，\n看看今天涨了多少")
                .font(Typeface.title(30))
                .foregroundStyle(Palette.ink)
            Text("你所有产品的新增用户、收入和商店评论，一个按钮全部刷新。")
                .font(.system(size: 15))
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            Button("连接我的产品") { adding = true }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("startConnecting")
                .padding(.top, 28)
            Button("先用示例数据看看") {
                model.update { $0.demoMode = true }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier("tryDemo")
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 8)
        .catPanel(cat)
    }

    /// The numbers spin and land one by one while the cat comes up for a sniff, then it grins and stays.
    private func play() async {
        spinning = spinning.map { _ in true }
        try? await Task.sleep(for: .milliseconds(400))
        cat = CatState(out: true, sniffing: true)
        try? await Task.sleep(for: .milliseconds(900))
        for index in spinning.indices {
            spinning[index] = false
            model.feedback.tick(column: index)
            try? await Task.sleep(for: .milliseconds(320))
        }
        try? await Task.sleep(for: .milliseconds(300))
        cat = CatState(out: true, reaction: .glee, reactionToken: 1)
        try? await Task.sleep(for: .milliseconds(900))
        cat = CatState(out: true)
    }
}
