import SnuffleKit
import SwiftUI

/// Rename, recolour, change how numbers are counted, connect more sources, or delete a project.
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
        NavigationStack {
            Form {
                Section("名称和颜色") {
                    TextField("项目名称", text: $draft.name)
                    TintPicker(tint: $draft.tint)
                    Toggle("一键刷新时包含它", isOn: $draft.includeInRefresh)
                }
                Section("数据源") {
                    ForEach(Platform.allCases) { platform in
                        let linked = draft.platforms.contains(platform)
                        HStack {
                            PlatformMark(platform: platform)
                            Text(platform.displayName)
                            Spacer()
                            if linked {
                                Button("断开", role: .destructive) { unlink(platform) }
                                    .buttonStyle(.borderless)
                            } else {
                                Button("连接") { connecting = platform }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                MetricsSection(project: $draft)
                Section {
                    Button("删除项目", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle("编辑项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        model.save(project: draft)
                        dismiss()
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("删除 \(draft.name)？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除项目", role: .destructive) {
                    model.delete(project: draft)
                    dismiss()
                }
            } message: {
                Text("只删除 Snuffle 里的这个项目，你在各平台的数据不受影响。登录过的账号会保留。")
            }
            .sheet(item: $connecting) { platform in
                SourceConnectSheet(platform: platform, project: $draft)
            }
        }
    }

    private func unlink(_ platform: Platform) {
        switch platform {
        case .posthog: draft.posthog = nil
        case .revenueCat:
            draft.revenueCat = nil
            if draft.metrics.revenue == .revenueCat { draft.metrics.revenue = .none }
        case .appStore: draft.appStore = nil
        case .googlePlay: draft.googlePlay = nil
        }
    }
}

struct TintPicker: View {
    @Binding var tint: ProjectTint

    var body: some View {
        HStack(spacing: 12) {
            ForEach(ProjectTint.allCases, id: \.self) { item in
                Button {
                    tint = item
                } label: {
                    Circle()
                        .fill(item.color)
                        .frame(width: 30, height: 30)
                        .overlay(Circle().strokeBorder(Palette.ink, lineWidth: tint == item ? 3 : 0).padding(-4))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(tint == item ? .isSelected : [])
            }
        }
    }
}

/// How new users, revenue and the extra number are counted.
struct MetricsSection: View {
    @Binding var project: Project

    private enum NewUsersChoice: String, CaseIterable { case signup, firstSeen, custom }
    private enum RevenueChoice: String, CaseIterable { case posthog, revenueCat, none }
    private enum ExtraChoice: String, CaseIterable { case installs, custom, none }

    var body: some View {
        Section {
            Picker("新增用户怎么算", selection: newUsersChoice) {
                Text("注册事件").tag(NewUsersChoice.signup)
                Text("第一次出现的人").tag(NewUsersChoice.firstSeen)
                Text("自定义事件").tag(NewUsersChoice.custom)
            }
            if case .event(let name) = project.metrics.newUsers {
                TextField("事件名", text: Binding(get: { name }, set: { project.metrics.newUsers = .event($0) }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("新增用户")
        } footer: {
            Text("注册事件按 PostHog 里这个事件的次数算，默认 user_signed_up；第一次出现的人按 PostHog 新建的用户档案算，包括没注册的访客。")
        }

        Section {
            Picker("收入来自", selection: revenueChoice) {
                Text("PostHog 付费事件").tag(RevenueChoice.posthog)
                if project.revenueCat != nil { Text("RevenueCat").tag(RevenueChoice.revenueCat) }
                Text("不统计").tag(RevenueChoice.none)
            }
            if case .posthogEvent(let event, let property) = project.metrics.revenue {
                TextField("事件名", text: Binding(get: { event }, set: { project.metrics.revenue = .posthogEvent(event: $0, valueProperty: property) }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("金额属性", text: Binding(get: { property }, set: { project.metrics.revenue = .posthogEvent(event: event, valueProperty: $0) }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("收入")
        } footer: {
            Text("PostHog 付费事件会把这个事件的金额属性加起来，并能列出每一笔订单；RevenueCat 只给每天的总额。金额按美元显示。")
        }

        Section("卡片上的第二个数") {
            Picker("显示", selection: extraChoice) {
                Text("今天的安装数").tag(ExtraChoice.installs)
                Text("自定义事件次数").tag(ExtraChoice.custom)
                Text("不显示").tag(ExtraChoice.none)
            }
            if case .event(let name, let label) = project.metrics.extra {
                TextField("事件名", text: Binding(get: { name }, set: { project.metrics.extra = .event(name: $0, label: label) }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("显示为，例如：次付费墙浏览", text: Binding(get: { label }, set: { project.metrics.extra = .event(name: name, label: $0) }))
            }
        }
    }

    private var newUsersChoice: Binding<NewUsersChoice> {
        Binding {
            switch project.metrics.newUsers {
            case .firstSeen: .firstSeen
            case .event(let name): name == "user_signed_up" ? .signup : .custom
            }
        } set: { choice in
            switch choice {
            case .signup: project.metrics.newUsers = .event("user_signed_up")
            case .firstSeen: project.metrics.newUsers = .firstSeen
            case .custom: project.metrics.newUsers = .event("")
            }
        }
    }

    private var revenueChoice: Binding<RevenueChoice> {
        Binding {
            switch project.metrics.revenue {
            case .posthogEvent: .posthog
            case .revenueCat: .revenueCat
            case .none: RevenueChoice.none
            }
        } set: { choice in
            switch choice {
            case .posthog: project.metrics.revenue = .posthogEvent(event: "purchase", valueProperty: "value")
            case .revenueCat: project.metrics.revenue = .revenueCat
            case .none: project.metrics.revenue = .none
            }
        }
    }

    private var extraChoice: Binding<ExtraChoice> {
        Binding {
            switch project.metrics.extra {
            case .installs: .installs
            case .event: .custom
            case .none: ExtraChoice.none
            }
        } set: { choice in
            switch choice {
            case .installs: project.metrics.extra = .installs
            case .custom: project.metrics.extra = .event(name: "", label: "次")
            case .none: project.metrics.extra = .none
            }
        }
    }
}
