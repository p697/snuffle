import SnuffleKit
import SwiftUI

/// Pages of the connect flows.
enum ConnectRoute: Hashable {
    case connect(Platform)
    case pickPostHog
    case importBoard
    case done(Platform)
    case connected
    case metrics
}

/// Adding a project: connect one source first (PostHog suggested), bring its PostHog dashboard over, see today's
/// numbers right away with the other sources one tap away, then name it. The name, colour, picture and counting are
/// filled in from what was connected and can be changed on the last page.
struct AddProjectFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The first project from the welcome screen also offers sample data instead.
    var offersDemo = false
    /// Opened by a key file: go straight to that source's page.
    var startsAt: Platform?
    @State private var session = ConnectSession(project: Project(name: "", tint: .ink), isNewProject: true)
    @State private var path: [ConnectRoute] = []
    @State private var saved = false

    var body: some View {
        NavigationStack(path: $path) {
            StartPage(offersDemo: offersDemo, postHogSignedIn: postHogSignedIn) { path.append(.connect($0)) }
                .navigationDestination(for: ConnectRoute.self, destination: page)
        }
        .environment(session)
        .onAppear {
            model.openConnectFlows += 1
            // A different colour for each new project.
            let used = Set(model.workspace.projects.map(\.tint))
            session.project.tint = ProjectTint.allCases.first { !used.contains($0) } ?? .ink
            if let startsAt { path = [.connect(startsAt)] }
        }
        .onDisappear {
            model.openConnectFlows -= 1
            if !saved { session.discard() }
        }
        // A key file opened from Files or AirDrop while this flow is up: show the App Store page, which takes it.
        .onChange(of: model.openedKeyFile) { _, file in
            if file != nil, path.last != .connect(.appStore) { path.append(.connect(.appStore)) }
        }
    }

    @ViewBuilder
    private func page(_ route: ConnectRoute) -> some View {
        switch route {
        case .connect(.posthog): PostHogConnectPage(signedIn: postHogSignedIn)
        case .connect(.revenueCat): RevenueCatConnectPage { path.append(.done(.revenueCat)) }
        case .connect(.appStore): AppStoreConnectPage { path.append(.done(.appStore)) }
        case .connect(.googlePlay): GooglePlayConnectPage { path.append(.done(.googlePlay)) }
        case .pickPostHog: PostHogPickPage(chosen: postHogLinked)
        case .importBoard: ImportBoardPage(next: showConnected)
        case .done(.revenueCat): RevenueCatDonePage(next: showConnected)
        case .done(let platform): StoreDonePage(platform: platform, next: showConnected)
        case .connected:
            ConnectedPage(
                addSource: { path.append(.connect($0)) },
                importDashboard: { path.append(.importBoard) },
                adjust: { path.append(.metrics) },
                merge: merge,
                finish: finish
            )
        case .metrics: MetricsPage()
        }
    }

    /// One PostHog project is obviously the one; several need a choice.
    private func postHogSignedIn() async {
        if session.postHogProjects.count == 1, let account = session.postHogAccount {
            await PostHogLinker.link(session.postHogProjects[0], account: account, session: session, model: model)
            postHogLinked()
        } else {
            path.append(.pickPostHog)
        }
    }

    /// A PostHog project with dashboards offers them next; otherwise straight to the summary.
    private func postHogLinked() {
        if session.postHogDashboards?.isEmpty == false {
            path.append(.importBoard)
        } else {
            showConnected()
        }
    }

    /// Back to the summary if it is already in the stack (a source added from there), otherwise to it for the first time.
    private func showConnected() {
        if let index = path.firstIndex(of: .connected) {
            path.removeSubrange(path.index(after: index)...)
        } else {
            path = [.connected]
        }
    }

    private func finish() {
        saved = true
        model.save(project: session.finished)
        dismiss()
        Task { await model.refreshAll(trigger: .connect) }
    }

    /// The new sources go into the project the person already had for this product, instead of a second one.
    private func merge(into twin: Project) {
        let merged = twin.merging(session.finished)
        model.save(project: merged)
        dismiss()
        Task { await model.refresh([merged], trigger: .connect) }
    }
}

// MARK: Start

/// "添加一个项目": what a project is, PostHog in a big card with its sign-in right there, the others below with what
/// each brings and what connecting it takes.
private struct StartPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    var offersDemo: Bool
    var postHogSignedIn: () async -> Void
    var open: (Platform) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    RoundIconButton(systemName: "xmark", label: String(localized: "关闭")) { dismiss() }
                    Spacer()
                    if offersDemo {
                        Button("先用示例数据看看") {
                            model.update { $0.demoMode = true }
                            dismiss()
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("startDemo")
                    }
                }
                PageTitle(
                    title: model.workspace.projects.isEmpty ? String(localized: "添加你的第一个项目") : String(localized: "添加一个项目"),
                    subtitle: String(localized: "一个项目就是你的一个产品。先接上它的一个数据源，其余的下一步在同一页补上。")
                )
                .padding(.top, 4)
                sources
                postHogCard
                SectionLabel(String(localized: "也可以先接"))
                    .padding(.top, 4)
                CardGroup {
                    ForEach(Array([Platform.revenueCat, .appStore, .googlePlay].enumerated()), id: \.element) { index, platform in
                        if index > 0 { RowDivider() }
                        Button {
                            open(platform)
                        } label: {
                            HStack(spacing: 12) {
                                PlatformLogo(platform: platform, size: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(platform.displayName).font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.ink)
                                    Text(verbatim: platform.purpose + " · " + platform.howToConnect)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Palette.ink2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Image(systemName: "chevron.forward").font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.faint)
                            }
                            .frame(minHeight: 68)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("connect-\(platform.rawValue)")
                    }
                }
                Text("账号和密钥只存在这台 iPhone 上，\n不会经过我们的服务器。")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
            .padding(16)
        }
        .sheetPage()
    }

    /// The four sources one project can read, side by side.
    private var sources: some View {
        HStack(spacing: 6) {
            ForEach(Platform.allCases) { platform in
                PlatformLogo(platform: platform, size: 28)
            }
            Text("都可以汇进同一个项目")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink2)
                .padding(.leading, 4)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var postHogCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PlatformLogo(platform: .posthog, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "PostHog").font(.system(size: 20, weight: .heavy)).foregroundStyle(Palette.ink)
                    Text("用户数、活跃、新增，还能导入你的看板")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Text("建议先连")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Palette.onAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(accent, in: Capsule())
            }
            PostHogSignIn(signedIn: postHogSignedIn)
        }
        .padding(18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Palette.ink, lineWidth: 2))
    }
}

// MARK: Connected

/// "项目建好了": today's numbers on the real home card, the dashboard brought over, the other sources one tap away with
/// what each adds, then the name and colour. A product that already has a project is offered to go into it instead.
private struct ConnectedPage: View {
    @Environment(ConnectSession.self) private var session
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var addSource: (Platform) -> Void
    var importDashboard: () -> Void
    var adjust: () -> Void
    var merge: (Project) -> Void
    var finish: () -> Void
    @State private var preview: ProjectSnapshot?
    @State private var loading = false
    @State private var confirmingCancel = false
    /// "不是同一个": the person wants a project of its own.
    @State private var keepApart = false

    var body: some View {
        @Bindable var session = session
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    RoundIconButton(systemName: "xmark", label: String(localized: "不保存，关闭")) { confirmingCancel = true }
                    Spacer()
                }
                if !keepApart, let twin = model.workspace.sameProduct(as: session.project) {
                    MergeCard(twin: twin, adding: session.project.platforms, merge: { merge(twin) }, keepApart: { keepApart = true })
                }
                PageTitle(title: String(localized: "项目建好了"), subtitle: session.project.name.isEmpty ? nil : String(localized: "这是 \(session.project.name) 今天到现在的数。"))
                ProjectCard(project: session.finished, preview: preview, previewLoading: loading)
                if session.project.posthog != nil { dashboardRow }
                let complete = session.project.platforms.count == Platform.allCases.count
                SectionLabel(complete ? String(localized: "数据源") : String(localized: "补全数据源 · 同一个产品的其他数据"))
                    .padding(.top, 6)
                SourceRows(project: session.project, connect: addSource)
                if !complete {
                    Text("现在不接也行，之后在项目页的「数据来源」里随时补。")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink2)
                        .padding(.horizontal, 6)
                }
                SectionLabel(String(localized: "图标、名称和颜色"))
                    .padding(.top, 6)
                identity($session.project)
                if session.project.posthog != nil || session.project.revenueCat != nil {
                    Button("数不对？调整怎么算", action: adjust)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink2)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .trailing)
                        .padding(.horizontal, 4)
                }
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) {
            Button("完成", action: finish)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(session.project.name.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("finishProject")
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .background(Palette.paper.opacity(0.95))
        }
        .sheetPage()
        .navigationBarBackButtonHidden()
        .interactiveDismissDisabled()
        .task(id: numbersKey) { await loadPreview() }
        .confirmationDialog("不保存这个项目？", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("不保存，关闭", role: .destructive) { dismiss() }
            Button("继续设置", role: .cancel) {}
        } message: {
            Text("登录过的账号会保留，下次添加时可以直接用。")
        }
    }

    /// The dashboard brought over, or the offer to bring one.
    @ViewBuilder
    private var dashboardRow: some View {
        let project = session.project
        let name = project.metrics.dashboard?.name ?? project.pins.first?.dashboard.name
        let count = session.postHogDashboards?.count ?? 0
        if name != nil || count > 0 {
            Button(action: importDashboard) {
                HStack(spacing: 12) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name.map { String(localized: "已导入看板「\($0)」") } ?? String(localized: "没有导入看板"))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Palette.ink)
                        Text(name == nil ? String(localized: "你在 PostHog 有 \(count) 个看板") : importedDetail(project))
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink2)
                    }
                    Spacer(minLength: 8)
                    Text(name == nil ? String(localized: "导入") : String(localized: "改"))
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(Palette.ink)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 60)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("connectedDashboard")
        }
    }

    private func importedDetail(_ project: Project) -> String {
        let charts = project.pins.isEmpty ? nil : String(localized: "\(project.pins.count) 张图")
        let counting = project.metrics.dashboard == nil ? nil : String(localized: "数字按看板算")
        return [charts, counting].compactMap { $0 }.joined(separator: " · ")
    }

    private func identity(_ project: Binding<Project>) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                ProjectIconPicker(project: project)
                TextField("项目名称", text: project.name)
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(Palette.ink)
                    .submitLabel(.done)
                    .accessibilityIdentifier("projectName")
                Image(systemName: "pencil").foregroundStyle(Palette.ink2)
            }
            HStack {
                Text("颜色").font(.system(size: 15)).foregroundStyle(Palette.ink2)
                Spacer(minLength: 0)
                TintDots(tint: project.tint)
            }
        }
        .padding(18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// What decides the numbers; the name, colour and picture do not.
    private var numbersKey: Project {
        var key = session.project
        key.name = ""
        key.tint = .ink
        key.iconVersion = nil
        // Adopting the surfaces the first preview found must not read it again when they match the default.
        key.metrics.excludedSurfaces = key.metrics.surfacesLeftOut
        return key
    }

    private func loadPreview() async {
        loading = true
        let project = session.finished
        let result = await model.provider.refresh(project, metrics: Set(project.card.metrics), previous: nil)
        preview = result.snapshot
        if session.project.metrics.excludedSurfaces == nil, let excluded = result.excludedSurfaces {
            session.project.metrics.excludedSurfaces = excluded
        }
        loading = false
    }
}

/// "已经有「Isaac Codex」了": a new project going by the name of one the person has, which reads none of the same
/// sources, offered to go into that one.
private struct MergeCard: View {
    var twin: Project
    var adding: [Platform]
    var merge: () -> Void
    var keepApart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ProjectBadge(project: twin, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("已经有「\(twin.name)」了")
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(Palette.ink)
                    Text(twin.platforms.isEmpty
                         ? String(localized: "那个项目还没接数据源")
                         : String(localized: "那个项目现在接了 \(ListFormatter.localizedString(byJoining: twin.platforms.map(\.displayName)))"))
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink2)
                }
            }
            Text(String(localized: "要把刚连的 \(ListFormatter.localizedString(byJoining: adding.map(\.displayName))) 加进它里面吗？同一个产品放在一个项目里，数字和评论会在同一张卡上。"))
                .font(.system(size: 15))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "加到「\(twin.name)」"), action: merge)
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("mergeProject")
            Button("不是同一个，新建项目", action: keepApart)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink2)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .padding(18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Palette.ink, lineWidth: 2))
    }
}

/// "怎么算" on its own page, from the summary.
private struct MetricsPage: View {
    @Environment(ConnectSession.self) private var session

    var body: some View {
        @Bindable var session = session
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BackButton()
                PageTitle(title: String(localized: "怎么算"), subtitle: String(localized: "已按这个项目最近 30 天发过的事件选好，数不对再改。"))
                MetricsCard(project: $session.project)
            }
            .padding(16)
        }
        .sheetPage()
    }
}

// MARK: Connecting one more source to a saved project

/// Connects one platform to an existing project; writes the result back when done. PostHog with dashboards offers
/// them next, unless this is the sign-in the dashboard sheet itself asked for.
struct ConnectSourceSheet: View {
    var platform: Platform
    @Binding var project: Project
    var offersDashboards = true
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var session: ConnectSession
    @State private var path: [ConnectRoute] = []

    init(platform: Platform, project: Binding<Project>, offersDashboards: Bool = true) {
        self.platform = platform
        _project = project
        self.offersDashboards = offersDashboards
        _session = State(initialValue: ConnectSession(project: project.wrappedValue, isNewProject: false))
    }

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: ConnectRoute.self) { route in
                    switch route {
                    case .pickPostHog: PostHogPickPage(chosen: postHogLinked)
                    case .importBoard: ImportBoardPage(next: done)
                    case .done(.revenueCat): RevenueCatDonePage(next: done)
                    case .done(let platform): StoreDonePage(platform: platform, next: done)
                    default: EmptyView()
                    }
                }
        }
        .environment(session)
        .onAppear { model.openConnectFlows += 1 }
        .onDisappear { model.openConnectFlows -= 1 }
    }

    @ViewBuilder
    private var root: some View {
        switch platform {
        case .posthog:
            PostHogConnectPage {
                if session.postHogProjects.count == 1, let account = session.postHogAccount {
                    await PostHogLinker.link(session.postHogProjects[0], account: account, session: session, model: model)
                    postHogLinked()
                } else {
                    path.append(.pickPostHog)
                }
            }
        case .revenueCat: RevenueCatConnectPage { path.append(.done(.revenueCat)) }
        case .appStore: AppStoreConnectPage { path.append(.done(.appStore)) }
        case .googlePlay: GooglePlayConnectPage { path.append(.done(.googlePlay)) }
        }
    }

    private func postHogLinked() {
        // Signing in again to the same PostHog project keeps what was imported from its dashboards.
        let sameProject = session.original?.posthog?.projectId == session.project.posthog?.projectId
        if offersDashboards, !sameProject || session.project.pins.isEmpty, session.postHogDashboards?.isEmpty == false {
            path.append(.importBoard)
        } else {
            done()
        }
    }

    private func done() {
        project = session.finished
        dismiss()
    }
}

/// Lays children out left to right and wraps to a new line when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
