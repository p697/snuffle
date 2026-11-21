import SnuffleKit
import SwiftUI

/// First launch: what Snuffle does, then connect a project or look at sample data.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @State private var adding = false
    @State private var cat = CatState()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            hero
            VStack(alignment: .leading, spacing: 10) {
                Text("按一下，\n看看今天涨了多少")
                    .font(Typeface.title(34))
                    .foregroundStyle(Palette.ink)
                Text("把你所有产品的新增用户、收入和商店评论放在一个地方，一个按钮全部刷新。")
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.ink2)
            }
            VStack(alignment: .leading, spacing: 14) {
                Bullet(symbol: "waveform.path.ecg", text: "新增用户、活跃、在线人数，来自 PostHog")
                Bullet(symbol: "dollarsign.circle", text: "收入，来自 RevenueCat 或你的付费事件")
                Bullet(symbol: "text.bubble", text: "App Store 和 Google Play 的评论，直接回复")
            }
            Spacer(minLength: 0)
            Button("连接 PostHog，开始") { adding = true }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("startConnecting")
            Button("先用示例数据看看") {
                model.update { $0.demoMode = true }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier("tryDemo")
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)
        .padding(.bottom, 16)
        .background(Palette.paper)
        .sheet(isPresented: $adding) { AddProjectFlow() }
        .task {
            // The cat comes up for a sniff, then settles behind the button.
            try? await Task.sleep(for: .milliseconds(600))
            cat = CatState(out: true, sniffing: true)
            try? await Task.sleep(for: .seconds(2.4))
            cat = CatState(out: true, sniffing: false, reaction: .glee, reactionToken: 1)
            try? await Task.sleep(for: .milliseconds(900))
            cat = CatState()
        }
    }

    private var hero: some View {
        ZStack(alignment: .top) {
            Circle()
                .strokeBorder(Palette.faint, style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                .frame(width: 132, height: 132)
            ZStack(alignment: .top) {
                PeekingCat(state: cat, ready: false, buttonSize: 100)
                Circle()
                    .fill(accent)
                    .frame(width: 100, height: 100)
                    .overlay(RefreshArrow().stroke(Palette.onAccent, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)).frame(width: 46, height: 46))
                    .shadow(color: Palette.shadow.opacity(0.22), radius: 13, y: 12)
                CatPaws(out: cat.out, buttonSize: 100)
            }
            .padding(.top, 16)
            Text("+48")
                .font(Typeface.number(22))
                .foregroundStyle(Palette.stripText)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .background(Palette.strip, in: Capsule())
                .offset(x: 82, y: 6)
        }
        .frame(width: 132, height: 132, alignment: .top)
        .padding(.top, 30)
        .accessibilityHidden(true)
    }
}

private struct Bullet: View {
    var symbol: String
    var text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(text).font(.system(size: 15))
        }
        .foregroundStyle(Palette.ink)
    }
}
