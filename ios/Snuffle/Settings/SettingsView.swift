import SnuffleKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @State private var paywall = false
    @State private var scenario = DemoWorld.Scenario.natural

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("设置").font(Typeface.title(34)).foregroundStyle(Palette.ink)
                    Spacer()
                    RoundIconButton(systemName: "xmark", label: "完成") { dismiss() }
                }
                .padding(.leading, 4)
                if model.settings.demoMode { leaveDemo }
                pro
                SectionLabel("外观").padding(.top, 8)
                appearance
                SectionLabel("刷新").padding(.top, 8)
                CardGroup {
                    Toggle("打开 App 时自动刷新", isOn: setting(\.refreshOnOpen))
                    RowDivider()
                    Toggle("触感反馈", isOn: setting(\.haptics))
                    RowDivider()
                    Toggle("提示音", isOn: setting(\.sound))
                }
                .toggleStyle(InkToggleStyle())
                if Feature.replyDrafts { drafts }
                SectionLabel("示例数据").padding(.top, 8)
                demo
                links.padding(.top, 20)
            }
            .padding(16)
        }
        .background(Palette.paper.ignoresSafeArea())
        .sheet(isPresented: $paywall) { PaywallView(reason: .general) }
    }

    private var leaveDemo: some View {
        Button {
            model.update { $0.demoMode = false }
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("退出示例模式").font(.system(size: 17, weight: .heavy))
                    Text(model.workspace.projects.isEmpty ? "现在看的是示例数据，退出后连接你的产品" : "现在看的是示例数据，退出后回到你的项目")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.onAccent.opacity(0.7))
                }
                Spacer()
                Image(systemName: "arrow.right").font(.system(size: 15, weight: .heavy))
            }
            .foregroundStyle(Palette.onAccent)
            .padding(18)
            .background(accent, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settingsLeaveDemo")
    }

    private var pro: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                if !model.pro.isPro { paywall = true }
            } label: {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("Snuffle").font(.system(size: 19, weight: .heavy))
                            Text("Pro")
                                .font(.system(size: 12, weight: .heavy))
                                .foregroundStyle(Palette.onAccent)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 2)
                                .background(accent, in: Capsule())
                        }
                        Text(model.pro.isPro ? proPlan : (Feature.replyDrafts ? "起草回复 · " : "") + "不限项目 · 桌面和锁屏小组件 · 30 天历史")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.stripMuted)
                    }
                    Spacer(minLength: 8)
                    if !model.pro.isPro {
                        Text("看看 Pro")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(Palette.onAccent)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .background(accent, in: Capsule())
                    }
                }
                .foregroundStyle(Palette.stripText)
                .padding(18)
                .background(Palette.strip, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("upgradePro")
            Button("恢复购买") { Task { await model.pro.restore() } }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink2)
                .frame(minHeight: 36)
                .padding(.horizontal, 4)
        }
    }

    private var appearance: some View {
        VStack(spacing: 14) {
            ChoiceBar(options: [(AppSettings.Theme.system, "跟随系统"), (.light, "浅色"), (.dark, "深色")], selection: setting(\.theme))
                .accessibilityLabel("主题")
            HStack {
                Text("高亮色").font(.system(size: 15)).foregroundStyle(Palette.ink)
                Spacer()
                ForEach(AppSettings.Accent.allCases, id: \.self) { item in
                    Button {
                        model.update { $0.accent = item }
                    } label: {
                        Circle()
                            .fill(item.color)
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(Palette.ink, lineWidth: model.settings.accent == item ? 2.5 : 0).padding(-4))
                            .frame(width: 40, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.label)
                    .accessibilityAddTraits(model.settings.accent == item ? .isSelected : [])
                }
            }
        }
        .padding(18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var drafts: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("起草回复").padding(.top, 8)
            VStack(alignment: .leading, spacing: 12) {
                ChoiceBar(options: [(AppSettings.ReplyTone.warm, "亲切"), (.professional, "专业"), (.brief, "简短")], selection: setting(\.replyTone))
                TextField("署名，例如：Mia，Lumen Notes 开发者", text: setting(\.replySignature))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(Palette.pill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("起草时会把评论内容发给 Snuffle 的服务器和模型供应商生成草稿，不会保存评论正文。发布前你都可以修改。")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink2)
            }
            .padding(18)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private var demo: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: setting(\.demoMode)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("用示例数据看看")
                    Text("虚构的项目和数字，和你的账号互不影响").font(.system(size: 12)).foregroundStyle(Palette.ink2)
                }
            }
            .toggleStyle(InkToggleStyle())
            if model.settings.demoMode {
                Text("下一次刷新带来").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.ink2)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 6) {
                    ForEach(Array([(DemoWorld.Scenario.natural, "按真实速率"), (.sale, "一笔订单"), (.quiet, "什么都没变"), (.failure, "一个来源连不上")].enumerated()), id: \.offset) { _, item in
                        let chosen = scenario == item.0
                        Button {
                            scenario = item.0
                            Task { await model.setDemoScenario(item.0) }
                        } label: {
                            Text(item.1)
                                .font(.system(size: 13, weight: chosen ? .bold : .semibold))
                                .foregroundStyle(chosen ? Palette.paper : Palette.ink)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(chosen ? Palette.ink : Palette.pill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                }
            }
        }
        .padding(18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var links: some View {
        HStack(spacing: 14) {
            Link("隐私政策", destination: URL(string: "https://snuffle.ai/privacy")!)
            Text("·").foregroundStyle(Palette.ink2)
            Link("使用条款", destination: URL(string: "https://snuffle.ai/terms")!)
            Text("·").foregroundStyle(Palette.ink2)
            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").foregroundStyle(Palette.ink2)
        }
        .font(.system(size: 13, weight: .semibold))
        .tint(Palette.ink)
        .frame(maxWidth: .infinity)
    }

    private var proPlan: String {
        switch model.pro.activeProductId {
        case ProStore.monthly: "按月订阅中"
        case ProStore.yearly: "按年订阅中"
        case ProStore.lifetime: "已买断"
        default: "已开通"
        }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { value in model.update { $0[keyPath: keyPath] = value } })
    }
}
