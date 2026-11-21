import AuthenticationServices
import SnuffleKit
import SwiftUI
import UniformTypeIdentifiers

// One page per platform: sign in or paste a key, then pick what to read. Each calls `linked` once the project
// reads from it, and the flow around it decides where to go next.

/// Logo, title and what the platform brings, at the top of a connect page.
struct SourceHeader: View {
    var platform: Platform
    var title: String
    var subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            PlatformLogo(platform: platform, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Typeface.title(26)).foregroundStyle(Palette.ink)
                Text(subtitle).font(.system(size: 14)).foregroundStyle(Palette.ink2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

/// A tappable row inside a card: title, a grey line, and a chevron or a spinner.
struct ChoiceRow: View {
    var title: String
    var detail: String?
    var busy = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.ink)
                    if let detail {
                        Text(detail).font(.system(size: 13)).foregroundStyle(Palette.ink2).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if busy {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.forward").font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.faint)
                }
            }
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Accounts already signed in on a platform, so a second project does not ask to log in again.
private struct SavedAccounts: View {
    @Environment(AppModel.self) private var model
    var platform: Platform
    var busyId: UUID?
    var use: (Account) -> Void

    var body: some View {
        let accounts = model.workspace.accounts.filter { $0.platform == platform }
        if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(String(localized: "用已登录的账号"))
                CardGroup {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { RowDivider() }
                        ChoiceRow(title: account.title, detail: account.subtitle, busy: busyId == account.id) { use(account) }
                    }
                }
            }
        }
    }
}

/// A text field in a white card with an ink outline: the one thing to fill on the page.
private struct KeyField: View {
    var placeholder: LocalizedStringKey
    @Binding var text: String
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 10) {
            TextField(placeholder, text: $text)
                .font(.system(size: 16).monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(minHeight: 44)
            PasteButton(payloadType: String.self) { strings in
                if let first = strings.first { text = first.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            .labelStyle(.titleOnly)
            .buttonBorderShape(.capsule)
            .tint(accent)
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.ink, lineWidth: 2))
    }
}

/// The small print under a form.
private struct FinePrint: View {
    var text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

// MARK: PostHog

/// PostHog sign-in, used inside the start page's big card and on its own page.
struct PostHogSignIn: View {
    @Environment(ConnectSession.self) private var session
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth
    /// Awaited, so the button keeps saying it is busy while the flow links an obvious project.
    var signedIn: () async -> Void
    @State private var region = PostHogOAuth.Region.us
    @State private var useKey = false
    @State private var key = ""
    @State private var busy = false
    @State private var busyAccount: UUID?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if useKey {
                SecureField("phx_ 开头的个人 API 密钥", text: $key)
                    .font(.system(size: 16).monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .background(Palette.pill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Button(busy ? "验证中…" : "用这把密钥连接") { Task { await connectWithKey() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!key.hasPrefix("phx_") || busy)
                Text("在 PostHog 的 **设置 → 个人 API 密钥** 新建一把，权限勾选 project:read、query:read、user:read。")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink2)
            } else {
                Button(busy ? "等待授权…" : "用 PostHog 账号登录") { Task { await signIn() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(busy)
                    .accessibilityIdentifier("posthogSignIn")
            }
            HStack {
                Menu {
                    ForEach(PostHogOAuth.Region.allCases) { item in
                        Button(item.label) { region = item }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("数据在").foregroundStyle(Palette.ink2)
                        Text(region.label).fontWeight(.bold).foregroundStyle(Palette.ink)
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.ink)
                    }
                    .font(.system(size: 13))
                    .frame(minHeight: 36)
                }
                Spacer()
                Button(useKey ? "改用账号登录" : "改用 API 密钥") { useKey.toggle() }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
                    .frame(minHeight: 36)
            }
            ErrorText(text: error)
            SavedAccountsInline(platform: .posthog, busyId: busyAccount) { account in Task { await reuse(account) } }
        }
    }

    private func signIn() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let pkce = PKCE()
            let callback = try await webAuth.authenticate(
                using: PostHogOAuth.authorizeURL(region: region, pkce: pkce),
                callbackURLScheme: PostHogOAuth.callbackScheme,
                preferredBrowserSession: .shared
            )
            let code = try PostHogOAuth.code(from: callback, pkce: pkce)
            let token = try await PostHogOAuth.exchange(code: code, pkce: pkce, region: region)
            try await finish(credential: .posthogOAuth(token), bearer: token.accessToken)
        } catch let authError as ASWebAuthenticationSessionError where authError.code == .canceledLogin {
            return
        } catch {
            self.error = describe(error)
        }
    }

    private func connectWithKey() async {
        busy = true
        error = nil
        defer { busy = false }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await finish(credential: .posthogPersonalKey(host: region.host.absoluteString, key: trimmed), bearer: trimmed)
        } catch {
            self.error = describe(error)
        }
    }

    private func finish(credential: Credential, bearer: String) async throws {
        let result = try await PostHogClient(host: region.host) { bearer }.account()
        let saved = try model.add(
            account: Account(platform: .posthog, title: result.email ?? String(localized: "PostHog 个人密钥"), subtitle: region.label),
            credential: credential
        )
        session.postHogAccount = saved
        session.postHogProjects = result.projects
        await signedIn()
    }

    private func reuse(_ account: Account) async {
        busyAccount = account.id
        error = nil
        defer { busyAccount = nil }
        do {
            let (host, token) = try await TokenBroker(store: model.credentials).posthogToken(account.id)
            session.postHogProjects = try await PostHogClient(host: host) { token }.account().projects
            session.postHogAccount = account
            await signedIn()
        } catch {
            self.error = describe(error)
        }
    }
}

/// Signed-in accounts as quiet "用 … 继续" buttons, for inside a card.
private struct SavedAccountsInline: View {
    @Environment(AppModel.self) private var model
    var platform: Platform
    var busyId: UUID?
    var use: (Account) -> Void

    var body: some View {
        ForEach(model.workspace.accounts.filter { $0.platform == platform }) { account in
            Button {
                use(account)
            } label: {
                HStack(spacing: 8) {
                    Text("用 \(account.title) 继续").lineLimit(1)
                    if busyId == account.id { ProgressView().controlSize(.small) }
                }
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, minHeight: 48)
                .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1.5))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

/// PostHog on its own page, for adding it after another source.
struct PostHogConnectPage: View {
    var signedIn: () async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                BackButton()
                SourceHeader(platform: .posthog, title: String(localized: "连接 PostHog"), subtitle: Platform.posthog.purpose)
                PostHogSignIn(signedIn: signedIn)
                    .padding(18)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .padding(16)
        }
        .sheetPage()
    }
}

/// After signing in: one tap on a PostHog project links it, names the project and picks how to count.
struct PostHogPickPage: View {
    @Environment(ConnectSession.self) private var session
    @Environment(AppModel.self) private var model
    var chosen: () -> Void
    @State private var busyId: Int?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    BackButton()
                    Spacer()
                    SuccessBadge(text: String(localized: "PostHog 已登录"))
                }
                PageTitle(title: String(localized: "选一个产品"), subtitle: subtitle)
                if session.postHogProjects.isEmpty {
                    Text("这个账号下还没有项目。先在 PostHog 里建一个，或换一个账号登录。")
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.ink2)
                        .padding(.horizontal, 4)
                } else {
                    CardGroup {
                        ForEach(Array(session.postHogProjects.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { RowDivider() }
                            ChoiceRow(title: item.displayName, detail: detail(item), busy: busyId == item.id) {
                                Task { await choose(item) }
                            }
                            .disabled(busyId != nil)
                            .accessibilityIdentifier("posthogProject-\(item.id)")
                        }
                    }
                }
                ErrorText(text: error)
            }
            .padding(16)
        }
        .sheetPage()
    }

    private var subtitle: String {
        [session.postHogAccount?.title, String(localized: "\(session.postHogProjects.count) 个项目")].compactMap { $0 }.joined(separator: " · ")
    }

    private func detail(_ item: PostHogProject) -> String {
        [item.displayName == item.name ? item.organizationName : item.name, item.timezone].compactMap { $0 }.joined(separator: " · ")
    }

    private func choose(_ item: PostHogProject) async {
        guard let account = session.postHogAccount else { return }
        busyId = item.id
        defer { busyId = nil }
        await PostHogLinker.link(item, account: account, session: session, model: model)
        chosen()
    }
}

/// Links a PostHog project and picks counting defaults from the events it really sends.
enum PostHogLinker {
    static func link(_ item: PostHogProject, account: Account, session: ConnectSession, model: AppModel) async {
        session.project.posthog = PostHogLink(accountId: account.id, projectId: item.id, projectName: item.displayName, timeZone: item.timezone ?? TimeZone.current.identifier)
        if session.project.name.isEmpty { session.project.name = item.displayName }
        // Keep the standard defaults if the check fails.
        guard let (host, token) = try? await TokenBroker(store: model.credentials).posthogToken(account.id) else { return }
        let query = PostHogQueries.eventsSeen([MetricSettings.signupEvent, MetricSettings.installEvent], since: Date().addingTimeInterval(-30 * 86_400))
        guard let rows = try? await PostHogClient(host: host, token: { token }).query(projectId: item.id, query, name: "snuffle-defaults") else { return }
        let suggested = MetricSettings.suggested(seenEvents: PostHogParsing.eventNames(rows))
        session.project.metrics.newUsers = suggested.newUsers
        session.project.metrics.extra = suggested.extra
    }
}

// MARK: RevenueCat

struct RevenueCatConnectPage: View {
    @Environment(ConnectSession.self) private var session
    @Environment(AppModel.self) private var model
    var linked: () -> Void
    @State private var key = ""
    @State private var account: Account?
    @State private var busy = false
    @State private var busyAccount: UUID?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                BackButton()
                SourceHeader(platform: .revenueCat, title: String(localized: "连接 RevenueCat"), subtitle: String(localized: "每日收入、在订人数、试用和 MRR"))
                if account != nil, !session.revenueCatProjects.isEmpty {
                    projectList
                } else {
                    SavedAccounts(platform: .revenueCat, busyId: busyAccount) { saved in Task { await reuse(saved) } }
                    steps
                    KeyField(placeholder: "sk_ 开头的 V2 密钥", text: $key)
                        .accessibilityIdentifier("revenueCatKey")
                    Button(busy ? "验证中…" : "连接") { Task { await connect() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!key.hasPrefix("sk_") || busy)
                    ErrorText(text: error)
                    FinePrint(text: "这把密钥只能读，不能改任何东西。它只存在这台 iPhone 上，手机直接向 RevenueCat 请求。")
                }
            }
            .padding(16)
        }
        .sheetPage()
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 14) {
            NumberedStep(number: 1, text: "在 RevenueCat 打开 **项目设置 → API keys**，新建一把 **V2 密钥**。")
            NumberedStep(number: 2, text: "权限只开 **Charts metrics: overview** 和 **Project configuration: projects** 的读取，其他保持关闭。")
            NumberedStep(number: 3, text: "复制密钥，回到这里粘贴。")
            OutLink(title: String(localized: "打开 RevenueCat"), url: URL(string: "https://app.revenuecat.com")!)
                .padding(.leading, 38)
        }
        .padding(18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(String(localized: "选一个 RevenueCat 项目"))
            CardGroup {
                ForEach(Array(session.revenueCatProjects.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { RowDivider() }
                    ChoiceRow(title: item.name, detail: nil) { link(item) }
                }
            }
        }
    }

    private func connect() async {
        busy = true
        error = nil
        defer { busy = false }
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let found = try await RevenueCatClient(secretKey: secret).projects()
            let saved = try model.add(
                account: Account(platform: .revenueCat, title: found.map(\.name).formatted(.list(type: .and)).ifEmpty("RevenueCat"), subtitle: String(localized: "密钥 ••••\(String(secret.suffix(4)))")),
                credential: .revenueCat(secretKey: secret)
            )
            use(saved, projects: found)
        } catch {
            self.error = describe(error)
        }
    }

    private func reuse(_ saved: Account) async {
        busyAccount = saved.id
        error = nil
        defer { busyAccount = nil }
        do {
            guard case .revenueCat(let secret) = try model.credentials.credential(for: saved.id) else { return }
            use(saved, projects: try await RevenueCatClient(secretKey: secret).projects())
        } catch {
            self.error = describe(error)
        }
    }

    private func use(_ saved: Account, projects: [RevenueCatProject]) {
        account = saved
        session.revenueCatProjects = projects
        if let only = session.obvious(projects, names: { [$0.name] }) { link(only) }
    }

    private func link(_ item: RevenueCatProject) {
        guard let account else { return }
        session.project.revenueCat = RevenueCatLink(accountId: account.id, projectId: item.id, projectName: item.name)
        if session.project.metrics.revenue == .none || session.project.posthog == nil { session.project.metrics.revenue = .revenueCat }
        if session.project.name.isEmpty { session.project.name = item.name }
        linked()
    }
}

// MARK: App Store Connect

struct AppStoreConnectPage: View {
    @Environment(ConnectSession.self) private var session
    @Environment(AppModel.self) private var model
    var linked: () -> Void
    @State private var account: Account?
    @State private var issuerId = ""
    @State private var keyId = ""
    @State private var pem = ""
    @State private var importing = false
    @State private var busy = false
    @State private var busyAccount: UUID?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                BackButton()
                SourceHeader(platform: .appStore, title: String(localized: "连接 App Store"), subtitle: String(localized: "全部评论和回复状态，在这里直接回复"))
                if account != nil, !session.appStoreApps.isEmpty {
                    appList
                } else {
                    SavedAccounts(platform: .appStore, busyId: busyAccount) { saved in Task { await reuse(saved) } }
                    Text("Apple 不提供一键登录，需要一把密钥。大约两分钟，可以在电脑上生成后隔空投送到手机。")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                    steps
                    fileButton
                    fields
                    Button(busy ? "验证中…" : "导入并读取 App 列表") { Task { await connect() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(busy || pem.isEmpty || keyId.isEmpty || issuerId.isEmpty)
                    ErrorText(text: error)
                    FinePrint(text: "密钥只存在这台 iPhone 上，手机直接向 Apple 请求，不会经过我们的服务器。一把密钥能读这个团队的所有 App，下一个项目不用再导入。")
                }
            }
            .padding(16)
        }
        .sheetPage()
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data, .plainText, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                pem = text
                // Apple names the file AuthKey_<KEYID>.p8.
                let name = url.deletingPathExtension().lastPathComponent
                if keyId.isEmpty, name.hasPrefix("AuthKey_") { keyId = String(name.dropFirst("AuthKey_".count)) }
            } else {
                error = String(localized: "读不出这个文件，请确认是 Apple 下载的 .p8 密钥")
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 14) {
            NumberedStep(number: 1, text: "在 App Store Connect 打开 **用户和访问 → 集成 → 团队密钥**。")
            NumberedStep(number: 2, text: "生成一把密钥，权限选 **客户支持**（只能读评论和回复评论）。")
            NumberedStep(number: 3, text: "下载 **.p8 文件**，记下页面上的 **Issuer ID** 和 **密钥 ID**。")
            OutLink(title: String(localized: "打开 App Store Connect"), url: URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!)
                .padding(.leading, 38)
        }
        .padding(18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var fileButton: some View {
        Button {
            importing = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: pem.isEmpty ? "doc.badge.plus" : "checkmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: 44, height: 44)
                    .background(pem.isEmpty ? Color(hex: 0xFFDD33) : Palette.up, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(pem.isEmpty ? "选择 .p8 文件" : "已读取密钥文件").font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.ink)
                    Text(pem.isEmpty ? "文件名里的密钥 ID 会自动填上" : "点这里重新选择").font(.system(size: 13)).foregroundStyle(Palette.ink2)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Palette.faint, style: StrokeStyle(lineWidth: 2, dash: [6, 5])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var fields: some View {
        CardGroup {
            LabeledField(label: "密钥 ID", placeholder: "2X9R4HXF34", text: $keyId, capitalization: .characters, identifier: "ascKeyId")
            RowDivider()
            LabeledField(label: "Issuer ID", placeholder: "57246542-96fe-…", text: $issuerId, capitalization: .never, identifier: "ascIssuerId")
            if pem.isEmpty {
                RowDivider()
                TextField("或者直接粘贴 .p8 文件内容", text: $pem, axis: .vertical)
                    .lineLimit(2...5)
                    .font(.system(size: 13))
                    .accessibilityIdentifier("ascPem")
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.vertical, 12)
            }
        }
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(String(localized: "选一个 App"))
            CardGroup {
                ForEach(Array(session.appStoreApps.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { RowDivider() }
                    ChoiceRow(title: app.name, detail: app.bundleId) { link(app) }
                }
            }
        }
    }

    private func connect() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let token = try AppStoreConnectToken(issuerId: issuerId.trimmingCharacters(in: .whitespaces), keyId: keyId.trimmingCharacters(in: .whitespaces), privateKeyPEM: pem)
            let found = try await AppStoreConnectClient(token: token).apps()
            let saved = try model.add(
                account: Account(platform: .appStore, title: found.first.map { String(localized: "\($0.name) 等 \(found.count) 个 App") } ?? "App Store Connect", subtitle: String(localized: "密钥 \(token.keyId)")),
                credential: .appStoreConnect(issuerId: token.issuerId, keyId: token.keyId, privateKeyPEM: pem)
            )
            use(saved, apps: found)
        } catch {
            self.error = describe(error)
        }
    }

    private func reuse(_ saved: Account) async {
        busyAccount = saved.id
        error = nil
        defer { busyAccount = nil }
        do {
            guard case .appStoreConnect(let issuer, let key, let pem) = try model.credentials.credential(for: saved.id) else { return }
            use(saved, apps: try await AppStoreConnectClient(token: AppStoreConnectToken(issuerId: issuer, keyId: key, privateKeyPEM: pem)).apps())
        } catch {
            self.error = describe(error)
        }
    }

    private func use(_ saved: Account, apps: [AppStoreApp]) {
        account = saved
        session.appStoreApps = apps
        if let only = session.obvious(apps, names: { [$0.name, $0.bundleId] }) { link(only) }
    }

    private func link(_ app: AppStoreApp) {
        guard let account else { return }
        session.project.appStore = AppStoreLink(accountId: account.id, appId: app.id, appName: app.name, bundleId: app.bundleId)
        if session.project.name.isEmpty { session.project.name = app.name }
        linked()
    }
}

/// A label and a field on one row of a card.
private struct LabeledField: View {
    var label: LocalizedStringKey
    var placeholder: String
    @Binding var text: String
    var capitalization: TextInputAutocapitalization
    var identifier: String

    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 15)).foregroundStyle(Palette.ink2)
            TextField(text: $text) { Text(verbatim: placeholder) }
                .accessibilityIdentifier(identifier)
                .font(.system(size: 15).monospaced())
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(capitalization)
                .autocorrectionDisabled()
        }
        .frame(minHeight: 52)
    }
}

// MARK: Google Play

struct GooglePlayConnectPage: View {
    @Environment(ConnectSession.self) private var session
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth
    var linked: () -> Void
    @State private var account: Account?
    @State private var appsUnavailable = false
    @State private var loadingApps = false
    @State private var manualEntry = false
    @State private var packageName = ""
    @State private var busy = false
    @State private var busyApp: String?
    @State private var error: String?

    private var clientId: String? {
        (Bundle.main.object(forInfoDictionaryKey: "SnuffleGoogleClientID") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                BackButton()
                SourceHeader(platform: .googlePlay, title: String(localized: "连接 Google Play"), subtitle: String(localized: "评论和回复，在这里直接回复"))
                if account == nil || appsUnavailable {
                    SavedAccounts(platform: .googlePlay, busyId: nil) { saved in
                        account = saved
                        Task { await loadApps() }
                    }
                    signInCard
                }
                if account != nil {
                    if loadingApps {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                    } else if !session.googleApps.isEmpty {
                        appList
                    } else if !appsUnavailable {
                        Text("这个账号在 Google Play 管理中心里还没有 App。")
                            .font(.system(size: 15))
                            .foregroundStyle(Palette.ink2)
                            .padding(.horizontal, 4)
                    }
                    if manualEntry || appsUnavailable { manual }
                }
                ErrorText(text: error)
            }
            .padding(16)
        }
        .sheetPage()
    }

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if clientId == nil {
                Text("Google Play 登录还没开放，敬请期待。").foregroundStyle(Palette.ink2)
            } else {
                Button(busy ? "等待授权…" : appsUnavailable ? "重新登录以列出 App" : "用 Google 账号登录") { Task { await signIn() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(busy)
                Text(appsUnavailable
                     ? "这个登录还没有读取 App 列表的权限，重新登录一次就能直接选。"
                     : "用能打开 Google Play 管理中心的那个 Google 账号登录。只请求读取 App 列表、读取和回复评论的权限。")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(String(localized: "选一个 App"))
            CardGroup {
                ForEach(Array(session.googleApps.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { RowDivider() }
                    ChoiceRow(title: app.displayName, detail: app.packageName, busy: busyApp == app.packageName) {
                        Task { await link(app.packageName) }
                    }
                    .disabled(busyApp != nil)
                }
            }
            if !manualEntry {
                Button("列表里没有？手动填包名") { manualEntry = true }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
                    .frame(minHeight: 36)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var manual: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("包名，例如 com.example.app", text: $packageName)
                .font(.system(size: 16).monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Button(busyApp != nil ? "验证中…" : "读取评论确认") { Task { await link(packageName) } }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busyApp != nil || !packageName.contains("."))
        }
    }

    private func loadApps() async {
        guard let account else { return }
        loadingApps = true
        appsUnavailable = false
        defer { loadingApps = false }
        do {
            let token = try await TokenBroker(store: model.credentials).googleToken(account.id)
            session.googleApps = try await GooglePlayClient { token }.apps()
            if let only = session.obvious(session.googleApps, names: { [$0.displayName, $0.packageName] }) {
                await link(only.packageName)
            }
        } catch {
            // Usually a sign-in from before the app list was requested: offer to sign in again, or type the name.
            session.googleApps = []
            appsUnavailable = true
        }
    }

    private func signIn() async {
        guard let clientId else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let pkce = PKCE()
            let callback = try await webAuth.authenticate(
                using: GoogleOAuth.authorizeURL(clientId: clientId, pkce: pkce),
                callbackURLScheme: GoogleOAuth.callbackScheme(clientId: clientId),
                preferredBrowserSession: .shared
            )
            let code = try GoogleOAuth.code(from: callback, pkce: pkce)
            let (token, email) = try await GoogleOAuth.exchange(code: code, pkce: pkce, clientId: clientId)
            account = try model.add(account: Account(platform: .googlePlay, title: email ?? String(localized: "Google 账号"), subtitle: "Google Play"), credential: .googleOAuth(token))
            await loadApps()
        } catch let authError as ASWebAuthenticationSessionError where authError.code == .canceledLogin {
            return
        } catch {
            self.error = describe(error)
        }
    }

    /// Reading the reviews once confirms the account can see this app before it is linked.
    private func link(_ rawName: String) async {
        guard let account else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        busyApp = name
        error = nil
        defer { busyApp = nil }
        do {
            let token = try await TokenBroker(store: model.credentials).googleToken(account.id)
            _ = try await GooglePlayClient { token }.reviews(packageName: name, projectId: session.project.id)
            session.project.googlePlay = GooglePlayLink(accountId: account.id, packageName: name)
            if session.project.name.isEmpty {
                session.project.name = session.googleApps.first { $0.packageName == name }?.displayName ?? name
            }
            linked()
        } catch {
            self.error = describe(error)
        }
    }
}
