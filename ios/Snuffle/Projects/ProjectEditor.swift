import SnuffleKit
import SwiftUI

/// "项目设置": rename, re-picture, recolour, connect or disconnect sources, how revenue and people are counted, or
/// delete a project. Its card and its dashboard charts are changed from the project page's menu.
struct ProjectEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
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
                SectionLabel(String(localized: "数据来源"))
                    .padding(.top, 8)
                SourceRows(project: draft, connect: { connecting = $0 }, disconnect: { draft.unlink($0) })
                if draft.posthog != nil || draft.revenueCat != nil {
                    MetricsCard(project: $draft)
                        .padding(.top, 8)
                }
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
            Text("项目设置").font(.system(size: 17, weight: .heavy)).foregroundStyle(Palette.ink)
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

    private func save() {
        // Anything beyond name, colour and picture changes what the numbers are.
        var before = model.workspace.projects.first { $0.id == draft.id }
        before?.name = draft.name
        before?.tint = draft.tint
        before?.iconVersion = draft.iconVersion
        let changedNumbers = before != draft
        if let before, before.metrics != draft.metrics {
            Analytics.countingChanged(draft.metrics.dashboard != nil ? .dashboard : draft.metrics.isStandardPeople ? .standard : .manual, settings: draft.metrics)
        }
        model.save(project: draft)
        dismiss()
        // New sources or counting rules: fetch this project's numbers now instead of showing stale ones.
        if changedNumbers { Task { [draft] in await model.refresh([draft], trigger: .project) } }
    }
}
