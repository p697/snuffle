import SnuffleKit
import SwiftUI

/// Pages of the connect flows.
enum ConnectRoute: Hashable {
    case connect(Platform)
    case pickPostHog
    case importBoard
    case done(Platform)
    case connected
}

/// Adding a project: connect one source first (PostHog suggested), bring its PostHog dashboard over, then see the
/// project with today's numbers and its other sources one tap away. Name, picture, colour and counting are filled in
/// from what was connected; the name and picture can be changed on the last page, the rest in project settings.
struct AddProjectFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The first project from the welcome screen also offers sample data instead.
    var offersDemo = false
    /// Opened by a key file: go straight to that source's page.
    var startsAt: Platform?
    @State private var session = ConnectSession(project: Project(name: "", tint: .ink), isNewProject: true)
    @State private var path: [ConnectRoute] = []

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
        .onDisappear { model.openConnectFlows -= 1 }
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
            ConnectedPage(addSource: { path.append(.connect($0)) }, merge: merge, finish: finish)
        }
    }

    /// One PostHog project is obviously the one, unless another project reads it; otherwise a choice.
    private func postHogSignedIn() async {
        if let only = session.onlyFreePostHogProject(in: model.workspace), let account = session.postHogAccount {
            await PostHogLinker.link(only, account: account, session: session, model: model)
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
        session.keepIcon()
        model.save(project: session.finished)
        dismiss()
        Task { await model.refreshAll(trigger: .connect) }
    }

    /// The new sources go into the project the person already had for this product, instead of a second one.
    private func merge(into twin: Project) {
        session.dropIcon()
        let merged = twin.merging(session.finished)
        model.save(project: merged)
        dismiss()
        Task { await model.refresh([merged], trigger: .connect) }
    }
}

// MARK: Start

/// "添加项目": PostHog in a big card with its sign-in right there, the other three as tiles. No explanations: the
/// logos say what each is, and the page after shows a project holds all four.
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
                PageTitle(title: String(localized: "添加项目"))
                    .padding(.top, 4)
                postHogCard
                HStack(spacing: 10) {
                    ForEach([Platform.revenueCat, .appStore, .googlePlay]) { platform in
                        Button {
                            open(platform)
                        } label: {
                            VStack(spacing: 10) {
                                PlatformLogo(platform: platform, size: 44)
                                Text(platform.displayName)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("connect-\(platform.rawValue)")
                    }
                }
            }
            .padding(16)
        }
        .sheetPage()
    }

    private var postHogCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PlatformLogo(platform: .posthog, size: 44)
                Text(verbatim: "PostHog").font(.system(size: 20, weight: .heavy)).foregroundStyle(Palette.ink)
                Spacer(minLength: 4)
                Text("推荐")
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

/// The new project: its picture and name on top, today's numbers on the real home card, and its four sources as tiles
/// with the missing ones a tap away. A product that already has a project is asked about first.
private struct ConnectedPage: View {
    @Environment(ConnectSession.self) private var session
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var addSource: (Platform) -> Void
    var merge: (Project) -> Void
    var finish: () -> Void
    @State private var preview: ProjectSnapshot?
    @State private var loading = false
    @State private var confirmingCancel = false
    /// "另建一个": the person wants a project of its own.
    @State private var keepApart = false

    var body: some View {
        @Bindable var session = session
        // Until the person says it is another product, the page asks one thing: whether this goes into the project
        // they already have. Nothing on it saves a second one.
        let twin = keepApart ? nil : model.workspace.sameProduct(as: session.project)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    RoundIconButton(systemName: "xmark", label: String(localized: "不保存，关闭")) { confirmingCancel = true }
                    Spacer()
                }
                if let twin {
                    MergeCard(twin: twin, merge: { merge(twin) }, keepApart: { keepApart = true })
                }
                HStack(spacing: 14) {
                    ProjectIconPicker(project: $session.project)
                    TextField("项目名称", text: $session.project.name)
                        .font(Typeface.title(26))
                        .foregroundStyle(Palette.ink)
                        .submitLabel(.done)
                        .accessibilityIdentifier("projectName")
                    Image(systemName: "pencil").foregroundStyle(Palette.ink2)
                }
                .padding(.horizontal, 4)
                ProjectCard(project: session.finished, preview: preview, previewLoading: loading)
                SourceSlots(project: session.project, connect: addSource)
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) {
            if twin == nil {
                Button("完成", action: finish)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(session.project.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("finishProject")
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .background(Palette.paper.opacity(0.95))
            }
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

/// "已有「Isaac Codex」": a new project going by the name of one the person has, which reads none of the same sources,
/// offered to go into that one.
private struct MergeCard: View {
    var twin: Project
    var merge: () -> Void
    var keepApart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProjectBadge(project: twin, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("已有「\(twin.name)」")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(Palette.ink)
                    HStack(spacing: 4) {
                        ForEach(twin.platforms) { PlatformLogo(platform: $0, size: 18) }
                    }
                }
            }
            HStack(spacing: 10) {
                Button(String(localized: "加到这个项目"), action: merge)
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("mergeProject")
                Button(String(localized: "另建一个"), action: keepApart)
                    .buttonStyle(PrimaryButtonStyle(filled: false))
            }
        }
        .padding(18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Palette.ink, lineWidth: 2))
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
                if let only = session.onlyFreePostHogProject(in: model.workspace), let account = session.postHogAccount {
                    await PostHogLinker.link(only, account: account, session: session, model: model)
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

    /// A newly linked PostHog project offers its dashboards; signing in again to the same one changes nothing else.
    private func postHogLinked() {
        let sameProject = session.original?.posthog?.projectId == session.project.posthog?.projectId
        if offersDashboards, !sameProject, session.postHogDashboards?.isEmpty == false {
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
