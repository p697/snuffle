import SnuffleKit
import SwiftUI

/// Adding a project in two steps: connect sources, then say how its numbers are counted.
struct AddProjectFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var project = Project(name: "", tint: .ink)
    @State private var connecting: Platform?
    @State private var path: [Step] = []

    enum Step: Hashable { case metrics }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    TextField("项目名称（连接后会自动填）", text: $project.name)
                        .accessibilityIdentifier("projectName")
                } header: {
                    Text("第 1 步 · 连接数据源")
                } footer: {
                    Text("至少连一个。PostHog 提供新增用户、在线和收入事件；RevenueCat 提供收入；两个商店提供评论。")
                }
                Section {
                    ForEach(Platform.allCases) { platform in
                        Button {
                            connecting = platform
                        } label: {
                            HStack(spacing: 12) {
                                PlatformMark(platform: platform)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(platform.displayName).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
                                    Text(linkSummary(platform) ?? purpose(platform))
                                        .font(.system(size: 12))
                                        .foregroundStyle(linkSummary(platform) == nil ? Palette.ink2 : Palette.up)
                                }
                                Spacer()
                                Image(systemName: linkSummary(platform) == nil ? "plus.circle" : "checkmark.circle.fill")
                                    .foregroundStyle(linkSummary(platform) == nil ? Palette.ink2 : Palette.up)
                            }
                            .frame(minHeight: 52)
                        }
                        .accessibilityIdentifier("connect-\(platform.rawValue)")
                    }
                }
            }
            .navigationTitle("添加项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("下一步") { path.append(.metrics) }
                        .disabled(project.platforms.isEmpty)
                }
            }
            .navigationDestination(for: Step.self) { _ in
                Form {
                    MetricsSection(project: $project)
                    Section {
                        TintPicker(tint: $project.tint)
                    } header: {
                        Text("颜色")
                    }
                }
                .navigationTitle("第 2 步 · 定义指标")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { finish() }
                            .disabled(project.name.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("finishProject")
                    }
                }
            }
            .sheet(item: $connecting) { platform in
                SourceConnectSheet(platform: platform, project: $project)
            }
            .onAppear {
                // A different colour for each new project.
                let used = Set(model.workspace.projects.map(\.tint))
                project.tint = ProjectTint.allCases.first { !used.contains($0) } ?? .ink
            }
        }
    }

    private func purpose(_ platform: Platform) -> String {
        switch platform {
        case .posthog: "新增用户、活跃、在线、付费事件"
        case .revenueCat: "每日收入、订阅概况"
        case .appStore: "评论和回复"
        case .googlePlay: "近 7 天评论和回复"
        }
    }

    private func linkSummary(_ platform: Platform) -> String? {
        switch platform {
        case .posthog: project.posthog.map { "已连接 · \($0.projectName)" }
        case .revenueCat: project.revenueCat.map { "已连接 · \($0.projectName)" }
        case .appStore: project.appStore.map { "已连接 · \($0.appName)" }
        case .googlePlay: project.googlePlay.map { "已连接 · \($0.packageName)" }
        }
    }

    private func finish() {
        if project.posthog == nil, case .posthogEvent = project.metrics.revenue {
            project.metrics.revenue = project.revenueCat != nil ? .revenueCat : .none
        }
        model.save(project: project)
        dismiss()
        Task { await model.refreshAll() }
    }
}
