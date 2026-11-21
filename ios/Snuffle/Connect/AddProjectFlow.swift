import SnuffleKit
import SwiftUI

/// Pages of the connect flows.
enum ConnectRoute: Hashable {
    case connect(Platform)
    case pickPostHog
    case done(Platform)
    case connected
    case metrics
}

/// Adding a project: connect one source first (PostHog suggested), see today's numbers right away, then name it.
/// The name, colour and counting rules are filled in from what was connected and can be changed on the last page.
struct AddProjectFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The first project from the welcome screen also offers sample data instead.
    var offersDemo = false
    @State private var session = ConnectSession(project: Project(name: "", tint: .ink))
    @State private var path: [ConnectRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            StartPage(offersDemo: offersDemo, postHogSignedIn: postHogSignedIn) { path.append(.connect($0)) }
                .navigationDestination(for: ConnectRoute.self, destination: page)
        }
        .environment(session)
        .onAppear {
            // A different colour for each new project.
            let used = Set(model.workspace.projects.map(\.tint))
            session.project.tint = ProjectTint.allCases.first { !used.contains($0) } ?? .ink
        }
    }

    @ViewBuilder
    private func page(_ route: ConnectRoute) -> some View {
        switch route {
        case .connect(.posthog): PostHogConnectPage(signedIn: postHogSignedIn)
        case .connect(.revenueCat): RevenueCatConnectPage { path.append(.done(.revenueCat)) }
        case .connect(.appStore): AppStoreConnectPage { path.append(.done(.appStore)) }
        case .connect(.googlePlay): GooglePlayConnectPage { path.append(.done(.googlePlay)) }
        case .pickPostHog: PostHogPickPage(chosen: showConnected)
        case .done(.revenueCat): RevenueCatDonePage(next: showConnected)
        case .done(let platform): StoreDonePage(platform: platform, next: showConnected)
        case .connected:
            ConnectedPage(addSource: { path.append(.connect($0)) }, adjust: { path.append(.metrics) }, finish: finish)
        case .metrics: MetricsPage()
        }
    }

    /// One PostHog project is obviously the one; several need a choice.
    private func postHogSignedIn() async {
        if session.postHogProjects.count == 1, let account = session.postHogAccount {
            await PostHogLinker.link(session.postHogProjects[0], account: account, session: session, model: model)
            showConnected()
        } else {
            path.append(.pickPostHog)
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
        model.save(project: session.project)
        dismiss()
        Task { await model.refreshAll() }
    }
}

// MARK: Start

/// "先连上一个数据源": PostHog in a big card with its sign-in right there, the others below.
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
                    RoundIconButton(systemName: "xmark", label: "关闭") { dismiss() }
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
                PageTitle(title: "先连上一个\n数据源")
                    .padding(.top, 4)
                postHogCard
                SectionLabel("也可以先连别的")
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
                                    Text(platform.purpose).font(.system(size: 13)).foregroundStyle(Palette.ink2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.faint)
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

    private var postHogCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PlatformLogo(platform: .posthog, size: 44)
                Text("PostHog").font(.system(size: 20, weight: .heavy)).foregroundStyle(Palette.ink)
                Spacer()
                Text("建议先连")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Palette.onAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(accent, in: Capsule())
            }
            HStack(spacing: 6) {
                ForEach(["新增用户", "在线人数", "活跃", "付费事件"], id: \.self) { Pill(text: $0) }
            }
            PostHogSignIn(signedIn: postHogSignedIn)
        }
        .padding(18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Palette.ink, lineWidth: 2))
    }
}

// MARK: Connected

/// "连上了": today's numbers on the real home card, the other sources one tap away, then the name and colour.
private struct ConnectedPage: View {
    @Environment(ConnectSession.self) private var session
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var addSource: (Platform) -> Void
    var adjust: () -> Void
    var finish: () -> Void
    @State private var preview: ProjectSnapshot?
    @State private var loading = false
    @State private var confirmingCancel = false

    var body: some View {
        @Bindable var session = session
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    RoundIconButton(systemName: "xmark", label: "不保存，关闭") { confirmingCancel = true }
                    Spacer()
                }
                PageTitle(title: "连上了", subtitle: session.project.name.isEmpty ? nil : "这是 \(session.project.name) 今天到现在的数。")
                ProjectCard(project: session.project, preview: preview, previewLoading: loading)
                SectionLabel(session.project.platforms.count == Platform.allCases.count ? "数据源" : "再连几个，数更全")
                    .padding(.top, 6)
                FlowLayout(spacing: 8) {
                    ForEach(Platform.allCases) { platform in
                        SourceChip(platform: platform, connected: session.project.platforms.contains(platform)) { addSource(platform) }
                    }
                }
                SectionLabel("图标、名称和颜色")
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
            Button("完成，去今日", action: finish)
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
        return key
    }

    private func loadPreview() async {
        loading = true
        let result = await model.provider.refresh(session.project)
        preview = result.snapshot
        loading = false
    }
}

/// A source on the "连上了" page: green with a tick when connected, otherwise a button to add it.
private struct SourceChip: View {
    var platform: Platform
    var connected: Bool
    var add: () -> Void

    var body: some View {
        if connected {
            label.accessibilityElement(children: .ignore).accessibilityLabel("\(platform.displayName) 已连接")
        } else {
            Button(action: add) { label }
                .buttonStyle(.plain)
                .accessibilityLabel("连接 \(platform.displayName)")
                .accessibilityIdentifier("addSource-\(platform.rawValue)")
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            PlatformLogo(platform: platform, size: 28)
            Text(platform.displayName).font(.system(size: 14, weight: .bold))
            Image(systemName: connected ? "checkmark" : "plus").font(.system(size: 12, weight: .heavy))
        }
        .foregroundStyle(connected ? Palette.up : Palette.ink)
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(minHeight: 44)
        .background(connected ? Palette.upSoft : Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(connected ? .clear : Palette.line))
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
                PageTitle(title: "怎么算", subtitle: "已按这个项目最近 30 天发过的事件选好，数不对再改。")
                MetricsCard(project: $session.project)
            }
            .padding(16)
        }
        .sheetPage()
    }
}

// MARK: Connecting one more source from the editor

/// Connects one platform to an existing project from the editor; writes the result back when done.
struct ConnectSourceSheet: View {
    var platform: Platform
    @Binding var project: Project
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var session: ConnectSession
    @State private var path: [ConnectRoute] = []

    init(platform: Platform, project: Binding<Project>) {
        self.platform = platform
        _project = project
        _session = State(initialValue: ConnectSession(project: project.wrappedValue))
    }

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: ConnectRoute.self) { route in
                    switch route {
                    case .pickPostHog: PostHogPickPage(chosen: done)
                    case .done(.revenueCat): RevenueCatDonePage(next: done)
                    case .done(let platform): StoreDonePage(platform: platform, next: done)
                    default: EmptyView()
                    }
                }
        }
        .environment(session)
    }

    @ViewBuilder
    private var root: some View {
        switch platform {
        case .posthog:
            PostHogConnectPage {
                if session.postHogProjects.count == 1, let account = session.postHogAccount {
                    await PostHogLinker.link(session.postHogProjects[0], account: account, session: session, model: model)
                    done()
                } else {
                    path.append(.pickPostHog)
                }
            }
        case .revenueCat: RevenueCatConnectPage { path.append(.done(.revenueCat)) }
        case .appStore: AppStoreConnectPage { path.append(.done(.appStore)) }
        case .googlePlay: GooglePlayConnectPage { path.append(.done(.googlePlay)) }
        }
    }

    private func done() {
        project = session.project
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
