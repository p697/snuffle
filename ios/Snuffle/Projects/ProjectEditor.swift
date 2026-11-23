import SnuffleKit
import SwiftUI

/// Rename, re-picture, recolour, connect more sources, change how numbers are counted, or delete a project.
struct ProjectEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @State private var draft: Project
    @State private var confirmDelete = false
    @State private var connecting: Platform?

    init(project: Project) {
        _draft = State(initialValue: project)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                identity
                    .padding(.top, 4)
                SectionLabel(String(localized: "数据源"))
                    .padding(.top, 8)
                sources
                SectionLabel(String(localized: "怎么算"))
                    .padding(.top, 8)
                MetricsCard(project: $draft)
                Button("删除项目", role: .destructive) { confirmDelete = true }
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.bad)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .overlay(Capsule().strokeBorder(Palette.badLine))
                    .padding(.top, 12)
                Text("只删除 Snuffle 里的这个项目，各平台的数据不受影响，登录过的账号会保留。")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(16)
        }
        .background(Palette.paper.ignoresSafeArea())
        .confirmationDialog("删除 \(draft.name)？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除项目", role: .destructive) {
                model.delete(project: draft)
                dismiss()
            }
        } message: {
            Text("只删除 Snuffle 里的这个项目，你在各平台的数据不受影响。登录过的账号会保留。")
        }
        .sheet(item: $connecting) { platform in
            ConnectSourceSheet(platform: platform, project: $draft)
        }
    }

    private var header: some View {
        HStack {
            RoundIconButton(systemName: "xmark", label: String(localized: "取消")) { dismiss() }
            Spacer()
            Text("编辑项目").font(.system(size: 17, weight: .heavy)).foregroundStyle(Palette.ink)
            Spacer()
            Button("保存", action: save)
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(Palette.paper)
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .background(Palette.ink, in: Capsule())
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(draft.name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.35 : 1)
        }
    }

    private var identity: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                ProjectIconPicker(project: $draft)
                TextField("项目名称", text: $draft.name)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(Palette.ink)
            }
            HStack {
                Text("颜色").font(.system(size: 15)).foregroundStyle(Palette.ink2)
                Spacer(minLength: 0)
                TintDots(tint: $draft.tint)
            }
            RowDivider()
            Toggle("一键刷新时包含它", isOn: $draft.includeInRefresh)
                .toggleStyle(InkToggleStyle())
        }
        .padding(18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var sources: some View {
        CardGroup {
            ForEach(Array(Platform.allCases.enumerated()), id: \.element) { index, platform in
                if index > 0 { RowDivider() }
                HStack(spacing: 12) {
                    PlatformLogo(platform: platform, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(platform.displayName).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
                        if let linked = linkName(platform) {
                            Text("已连接 · \(linked)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.up).lineLimit(1)
                        } else {
                            Text(platform.purpose).font(.system(size: 12)).foregroundStyle(Palette.ink2)
                        }
                    }
                    Spacer(minLength: 8)
                    if linkName(platform) != nil {
                        Button("断开") { unlink(platform) }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Palette.bad)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 34)
                            .overlay(Capsule().strokeBorder(Palette.line))
                            .frame(minHeight: 44)
                    } else {
                        Button("连接") { connecting = platform }
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(Palette.onAccent)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 34)
                            .background(accent, in: Capsule())
                            .frame(minHeight: 44)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 8)
            }
        }
    }

    private func linkName(_ platform: Platform) -> String? {
        switch platform {
        case .posthog: draft.posthog?.projectName
        case .revenueCat: draft.revenueCat?.projectName
        case .appStore: draft.appStore?.appName
        case .googlePlay: draft.googlePlay?.packageName
        }
    }

    private func unlink(_ platform: Platform) { draft.unlink(platform) }

    private func save() {
        // Anything beyond name, colour and picture changes what the numbers are.
        var before = model.workspace.projects.first { $0.id == draft.id }
        before?.name = draft.name
        before?.tint = draft.tint
        before?.iconVersion = draft.iconVersion
        let changedNumbers = before != draft
        model.save(project: draft)
        dismiss()
        // New sources or counting rules: fetch this project's numbers now instead of showing stale ones.
        if changedNumbers { Task { [draft] in await model.refresh([draft], trigger: .project) } }
    }
}
