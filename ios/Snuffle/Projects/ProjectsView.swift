import SnuffleKit
import SwiftUI

/// 项目: projects with their sources and refresh switches, and the accounts behind them.
struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openPaywall) private var openPaywall
    @State private var adding = false
    @State private var removing: Account?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScreenTitle(title: "项目", subtitle: model.settings.demoMode ? "示例数据，关掉示例后显示你自己的项目" : "\(model.projects.count) 个项目 · \(model.workspace.accounts.count) 个账号")
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 4, trailing: 12))
                }
                Section {
                    ForEach(model.projects) { project in
                        NavigationLink(value: project.id) {
                            ProjectRow(project: project)
                        }
                    }
                    .onMove(perform: model.settings.demoMode ? nil : { model.moveProjects(from: $0, to: $1) })
                    if !model.settings.demoMode {
                        Button {
                            if model.pro.isPro || model.projects.count < AppModel.freeProjectLimit {
                                adding = true
                            } else {
                                openPaywall(.projects)
                            }
                        } label: {
                            Label("添加项目", systemImage: "plus")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("addProject")
                    }
                } header: {
                    Text("项目")
                } footer: {
                    if !model.pro.isPro && !model.settings.demoMode {
                        Text("免费版可以添加两个项目，Pro 不限数量。")
                    }
                }
                if !model.settings.demoMode {
                    Section("账号") {
                        if model.workspace.accounts.isEmpty {
                            Text("添加项目时登录的账号会出现在这里。").foregroundStyle(Palette.ink2)
                        }
                        ForEach(model.workspace.accounts) { account in
                            AccountRow(account: account, usedBy: model.workspace.projects(using: account.id).count)
                                .swipeActions {
                                    Button("移除", role: .destructive) { removing = account }
                                }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .clearsTabBar()
            .background(Palette.paper)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { id in
                if let project = model.projects.first(where: { $0.id == id }) {
                    ProjectDetailView(project: project)
                }
            }
            .sheet(isPresented: $adding) { AddProjectFlow() }
            .confirmationDialog("移除这个账号？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { account in
                Button("移除 \(account.title)", role: .destructive) { model.remove(account: account) }
            } message: { account in
                let count = model.workspace.projects(using: account.id).count
                Text(count > 0 ? "有 \(count) 个项目在用它，移除后这些项目会断开 \(account.platform.displayName)。密钥会从这台手机上删除。" : "密钥会从这台手机上删除。")
            }
        }
    }
}

private struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    var project: Project

    var body: some View {
        HStack(spacing: 12) {
            ProjectBadge(project: project, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.system(size: 16, weight: .semibold))
                HStack(spacing: 4) {
                    ForEach(project.platforms) { platform in
                        let failing = model.snapshot(project.id)?.failures.contains { $0.platform == platform } ?? false
                        Text(platform.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(failing ? Palette.bad : Palette.ink2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(failing ? Palette.badSoft : Palette.pill, in: Capsule())
                    }
                }
            }
            Spacer()
            if model.isLocked(project) {
                Image(systemName: "lock.fill").foregroundStyle(Palette.ink2)
            } else if !project.includeInRefresh {
                Text("不刷新").font(.system(size: 12)).foregroundStyle(Palette.ink2)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AccountRow: View {
    var account: Account
    var usedBy: Int

    var body: some View {
        HStack(spacing: 12) {
            PlatformMark(platform: account.platform)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text("\(account.platform.displayName) · \(account.subtitle) · \(usedBy) 个项目在用")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A small square standing in for each platform, without using their logos.
struct PlatformMark: View {
    var platform: Platform

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Palette.ink)
            .frame(width: 32, height: 32)
            .background(Palette.pill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch platform {
        case .posthog: "chart.bar.xaxis"
        case .revenueCat: "dollarsign.arrow.circlepath"
        case .appStore: "apple.logo"
        case .googlePlay: "play.fill"
        }
    }
}
