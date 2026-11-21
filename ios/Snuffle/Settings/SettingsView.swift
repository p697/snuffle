import SnuffleKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var paywall = false
    @State private var scenario = DemoWorld.Scenario.natural

    var body: some View {
        NavigationStack {
            Form {
                if model.settings.demoMode {
                    Section {
                        Button {
                            model.update { $0.demoMode = false }
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("退出示例模式").font(.system(size: 17, weight: .bold))
                                Text(model.workspace.projects.isEmpty ? "现在看的是示例数据，退出后连接你的产品" : "现在看的是示例数据，退出后回到你的项目")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Palette.ink2)
                            }
                            .foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        }
                        .accessibilityIdentifier("settingsLeaveDemo")
                    }
                }
                Section {
                    Button {
                        if !model.pro.isPro { paywall = true }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.pro.isPro ? "Snuffle Pro" : "升级到 Snuffle Pro").font(.system(size: 17, weight: .bold))
                                Text(model.pro.isPro ? proPlan : (Feature.replyDrafts ? "起草回复、" : "") + "不限项目、桌面小组件、30 天历史")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Palette.ink2)
                            }
                            Spacer()
                            if !model.pro.isPro { Image(systemName: "chevron.right").foregroundStyle(Palette.ink2) }
                        }
                        .foregroundStyle(Palette.ink)
                        .frame(minHeight: 52)
                    }
                    .accessibilityIdentifier("upgradePro")
                    Button("恢复购买") { Task { await model.pro.restore() } }
                }

                Section("外观") {
                    Picker("主题", selection: setting(\.theme)) {
                        Text("跟随系统").tag(AppSettings.Theme.system)
                        Text("浅色").tag(AppSettings.Theme.light)
                        Text("深色").tag(AppSettings.Theme.dark)
                    }
                    HStack {
                        Text("高亮色")
                        Spacer()
                        ForEach(AppSettings.Accent.allCases, id: \.self) { accent in
                            Button {
                                model.update { $0.accent = accent }
                            } label: {
                                Circle()
                                    .fill(accent.color)
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().strokeBorder(Palette.ink, lineWidth: model.settings.accent == accent ? 3 : 0).padding(-4))
                                    .frame(width: 40, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(accent.label)
                            .accessibilityAddTraits(model.settings.accent == accent ? .isSelected : [])
                        }
                    }
                }

                Section("刷新") {
                    Toggle("打开 App 时自动刷新", isOn: setting(\.refreshOnOpen))
                    Toggle("触感反馈", isOn: setting(\.haptics))
                    Toggle("提示音", isOn: setting(\.sound))
                }

                if Feature.replyDrafts {
                    Section {
                        Picker("语气", selection: setting(\.replyTone)) {
                            Text("亲切").tag(AppSettings.ReplyTone.warm)
                            Text("专业").tag(AppSettings.ReplyTone.professional)
                            Text("简短").tag(AppSettings.ReplyTone.brief)
                        }
                        TextField("署名，例如：Mia，Lumen Notes 开发者", text: setting(\.replySignature))
                    } header: {
                        Text("起草回复")
                    } footer: {
                        Text("起草时会把评论内容发给 Snuffle 的服务器和模型供应商生成草稿，不会保存评论正文。发布前你都可以修改。")
                    }
                }

                Section {
                    Toggle("示例数据", isOn: setting(\.demoMode))
                    if model.settings.demoMode {
                        Picker("下一次刷新带来", selection: $scenario) {
                            Text("按真实速率").tag(DemoWorld.Scenario.natural)
                            Text("一笔订单").tag(DemoWorld.Scenario.sale)
                            Text("什么都没变").tag(DemoWorld.Scenario.quiet)
                            Text("一个来源连不上").tag(DemoWorld.Scenario.failure)
                        }
                        .onChange(of: scenario) { _, value in Task { await model.setDemoScenario(value) } }
                    }
                } footer: {
                    Text("示例数据里的项目、数字和评论都是虚构的，和你的账号互不影响。")
                }

                Section {
                    Link("隐私政策", destination: URL(string: "https://snuffle.ai/privacy")!)
                    Link("使用条款", destination: URL(string: "https://snuffle.ai/terms")!)
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .sheet(isPresented: $paywall) { PaywallView(reason: .general) }
        }
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
