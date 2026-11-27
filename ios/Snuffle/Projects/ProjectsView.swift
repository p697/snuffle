import SnuffleKit
import SwiftUI
import UniformTypeIdentifiers

/// 项目: the person's projects in one card, in the order the home screen shows them. Accounts have their own page.
struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @Environment(RootSheets.self) private var sheets
    @State private var adding = false
    @State private var dragging: UUID?

    enum Route: Hashable { case project(UUID), accounts }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    projects
                    footnote
                    if !model.settings.demoMode { accountsLink.padding(.top, 20) }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .clearsTabBar()
            .background(Palette.paper)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .project(let id):
                    if let project = model.projects.first(where: { $0.id == id }) { ProjectDetailView(project: project) }
                case .accounts:
                    AccountsView()
                }
            }
            .sheet(isPresented: $adding) { AddProjectFlow() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("项目").font(Typeface.title(40)).foregroundStyle(Palette.ink)
            if model.marksDemo {
                Text("示例").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink2)
            }
            Spacer()
            if !model.settings.demoMode {
                Button {
                    if model.canAddProject {
                        adding = true
                        Analytics.addProjectOpened(.projects)
                    } else {
                        sheets.openPaywall(.projects)
                    }
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(Palette.paper)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(Palette.ink, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("addProject")
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var projects: some View {
        if model.projects.isEmpty {
            Text("还没有项目。点右上角的添加，连上 PostHog 或商店后台就能开始刷新。")
                .font(.system(size: 15))
                .foregroundStyle(Palette.ink2)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else {
            CardGroup {
                ForEach(Array(model.projects.enumerated()), id: \.element.id) { index, project in
                    if index > 0 { RowDivider() }
                    NavigationLink(value: Route.project(project.id)) {
                        ProjectRow(project: project)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("projectRow-\(project.name)")
                    .opacity(dragging == project.id ? 0.4 : 1)
                    .modifier(Reorderable(project: project, dragging: $dragging, enabled: !model.settings.demoMode))
                }
            }
        }
    }

    @ViewBuilder
    private var footnote: some View {
        let lines = [
            model.projects.count > 1 && !model.settings.demoMode ? String(localized: "长按拖动可以调整顺序。") : nil,
            !model.pro.isPro && !model.settings.demoMode ? String(localized: "免费版可以添加两个项目，Pro 不限数量。") : nil,
            model.marksDemo ? String(localized: "示例数据，退出示例后显示你自己的项目。") : nil
        ].compactMap { $0 }
        if !lines.isEmpty {
            Text(lines.joined(separator: " "))
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink2)
                .padding(.horizontal, 4)
        }
    }

    private var accountsLink: some View {
        NavigationLink(value: Route.accounts) {
            HStack(spacing: 14) {
                Image(systemName: "key")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 44, height: 44)
                    .background(Palette.card, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.line))
                VStack(alignment: .leading, spacing: 2) {
                    Text("已登录的账号").font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.ink)
                    Text(model.workspace.accounts.isEmpty
                         ? String(localized: "登录 PostHog、RevenueCat 或 Google 后会在这里；App Store 不用登录")
                         : String(localized: "\(model.workspace.accounts.count) 个 · 只存在这台 iPhone 上", comment: "Number of signed-in accounts."))
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.forward").font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.faint)
            }
            .padding(16)
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Palette.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("accounts")
    }
}

/// Long press and drag a row onto another to move it there.
private struct Reorderable: ViewModifier {
    @Environment(AppModel.self) private var model
    var project: Project
    @Binding var dragging: UUID?
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrag {
                    dragging = project.id
                    return NSItemProvider(object: project.id.uuidString as NSString)
                }
                .onDrop(of: [.text], delegate: Drop(target: project.id, dragging: $dragging, model: model))
        } else {
            content
        }
    }

    private struct Drop: DropDelegate {
        var target: UUID
        @Binding var dragging: UUID?
        var model: AppModel

        func dropEntered(info: DropInfo) {
            guard let dragging, dragging != target,
                  let from = model.workspace.projects.firstIndex(where: { $0.id == dragging }),
                  let to = model.workspace.projects.firstIndex(where: { $0.id == target }) else { return }
            withAnimation(.snappy) {
                model.moveProjects(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
            }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

        func performDrop(info: DropInfo) -> Bool {
            dragging = nil
            return true
        }
    }
}

private struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    var project: Project

    var body: some View {
        HStack(spacing: 14) {
            ProjectBadge(project: project, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name).font(.system(size: 17, weight: .bold)).foregroundStyle(Palette.ink).lineLimit(1)
                Text(detail)
                    .font(.system(size: 13, weight: needsSignIn ? .semibold : .regular))
                    .foregroundStyle(needsSignIn ? Palette.warn : Palette.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.isLocked(project) {
                Image(systemName: "lock.fill").foregroundStyle(Palette.ink2)
            }
            Image(systemName: "chevron.forward").font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.faint)
        }
        .frame(minHeight: 72)
        .contentShape(Rectangle())
    }

    /// The failure to name: a sign-in first; sources the person muted are not named.
    private var failure: SourceFailure? {
        let failures = model.snapshot(project.id)?.failures.filter { !model.settings.mutedSources.contains($0.platform) } ?? []
        return failures.first { $0.kind?.needsSignIn == true } ?? failures.first
    }

    private var needsSignIn: Bool { failure?.kind?.needsSignIn == true }

    /// Plain grey sources, or the source that failed; coloured only when it needs signing in to again.
    private var detail: String {
        if let failure {
            let name = failure.platform.displayName
            return needsSignIn ? String(localized: "\(name) 要重新登录") : String(localized: "\(name) 没连上")
        }
        let sources = project.platforms.map(\.displayName).joined(separator: " · ")
        return project.includeInRefresh ? sources : sources + " · " + String(localized: "不参与一键刷新")
    }
}

/// 已登录的账号: what is stored on this phone, and removing it.
struct AccountsView: View {
    @Environment(AppModel.self) private var model
    @State private var removing: Account?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BackButton()
                PageTitle(title: String(localized: "已登录的账号"), subtitle: String(localized: "只存在这台 iPhone 上。添加下一个项目时可以直接用。"))
                if model.workspace.accounts.isEmpty {
                    Text("添加项目时登录的账号会出现在这里。")
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.ink2)
                        .padding(.horizontal, 4)
                } else {
                    CardGroup {
                        ForEach(Array(model.workspace.accounts.enumerated()), id: \.element.id) { index, account in
                            if index > 0 { RowDivider() }
                            row(account)
                        }
                    }
                    Text("移除后，用到它的项目会断开这个平台，密钥会从这台 iPhone 上删除。")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .clearsTabBar()
        .background(Palette.paper)
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog("移除这个账号？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { account in
            Button("移除 \(account.title)", role: .destructive) { model.remove(account: account) }
        } message: { account in
            let count = model.workspace.projects(using: account.id).count
            Text(count > 0 ? String(localized: "有 \(count) 个项目在用它。") + String(localized: "移除后这些项目会断开 \(account.platform.displayName)。密钥会从这台手机上删除。") : String(localized: "密钥会从这台手机上删除。"))
        }
    }

    private func row(_ account: Account) -> some View {
        HStack(spacing: 12) {
            PlatformLogo(platform: account.platform, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.title).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink).lineLimit(1)
                Text(verbatim: "\(account.platform.displayName) · \(account.subtitle) · " + String(localized: "\(model.workspace.projects(using: account.id).count) 个项目在用"))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("移除") { removing = account }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.bad)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .overlay(Capsule().strokeBorder(Palette.line))
                .frame(minHeight: 44)
                .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
    }
}
