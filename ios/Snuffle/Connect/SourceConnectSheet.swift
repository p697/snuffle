import AuthenticationServices
import SnuffleKit
import SwiftUI
import UniformTypeIdentifiers

/// Connects one platform to a project: reuse a signed-in account or add one, then pick what to read.
struct SourceConnectSheet: View {
    var platform: Platform
    @Binding var project: Project
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch platform {
                case .posthog: PostHogConnect(project: $project, done: { dismiss() })
                case .revenueCat: RevenueCatConnect(project: $project, done: { dismiss() })
                case .appStore: AppStoreConnect(project: $project, done: { dismiss() })
                case .googlePlay: GooglePlayConnect(project: $project, done: { dismiss() })
                }
            }
            .navigationTitle("连接 \(platform.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
    }
}

/// Lists accounts already signed in on a platform so a second project does not ask to log in again.
private struct ExistingAccounts: View {
    @Environment(AppModel.self) private var model
    var platform: Platform
    @Binding var selected: Account?

    var body: some View {
        let accounts = model.workspace.accounts.filter { $0.platform == platform }
        if !accounts.isEmpty {
            Section("已登录的账号") {
                ForEach(accounts) { account in
                    Button {
                        selected = account
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.title).foregroundStyle(Palette.ink)
                                Text(account.subtitle).font(.system(size: 12)).foregroundStyle(Palette.ink2)
                            }
                            Spacer()
                            if selected?.id == account.id { Image(systemName: "checkmark").foregroundStyle(Palette.ink) }
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
        }
    }
}

private struct ErrorText: View {
    var text: String?

    var body: some View {
        if let text {
            Text(text).font(.system(size: 14)).foregroundStyle(Palette.bad)
        }
    }
}

private func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}

// MARK: PostHog

private struct PostHogConnect: View {
    @Binding var project: Project
    var done: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var account: Account?
    @State private var region = PostHogOAuth.Region.us
    @State private var useKey = false
    @State private var key = ""
    @State private var busy = false
    @State private var error: String?
    @State private var projects: [PostHogProject] = []

    var body: some View {
        Form {
            ExistingAccounts(platform: .posthog, selected: $account)
            if account == nil {
                Section {
                    Picker("数据区域", selection: $region) {
                        ForEach(PostHogOAuth.Region.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if useKey {
                        SecureField("phx_ 开头的个人 API 密钥", text: $key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button(busy ? "验证中…" : "用这把密钥连接") { Task { await connectWithKey() } }
                            .disabled(!key.hasPrefix("phx_") || busy)
                    } else {
                        Button(busy ? "等待授权…" : "用 PostHog 账号登录") { Task { await signIn() } }
                            .disabled(busy)
                            .accessibilityIdentifier("posthogSignIn")
                    }
                    Button(useKey ? "改用账号登录" : "改用个人 API 密钥") { useKey.toggle() }
                        .font(.system(size: 14))
                } header: {
                    Text("新账号")
                } footer: {
                    Text(useKey
                         ? "在 PostHog 的 设置 → 个人 API 密钥 里新建一把，权限勾选 project:read、query:read、user:read 即可。密钥只存在这台手机的钥匙串里。"
                         : "会打开 PostHog 的授权页，只请求读取项目和查询数据的权限。")
                }
            }
            ErrorText(text: error)
            if !projects.isEmpty {
                Section("选择项目") {
                    ForEach(projects) { item in
                        Button {
                            Task { await choose(item) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.displayName).foregroundStyle(Palette.ink)
                                Text([item.displayName == item.name ? item.organizationName : item.name, item.timezone].compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.ink2)
                            }
                            .frame(minHeight: 44)
                        }
                        .disabled(busy)
                    }
                }
            }
        }
        .task(id: account?.id) {
            if account != nil { await loadProjects() }
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
            try await finish(credential: .posthogOAuth(token), host: region.host, bearer: token.accessToken)
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
            try await finish(credential: .posthogPersonalKey(host: region.host.absoluteString, key: trimmed), host: region.host, bearer: trimmed)
        } catch {
            self.error = describe(error)
        }
    }

    private func finish(credential: Credential, host: URL, bearer: String) async throws {
        let client = PostHogClient(host: host) { bearer }
        let result = try await client.account()
        let saved = try model.add(
            account: Account(platform: .posthog, title: result.email ?? "PostHog 个人密钥", subtitle: region.label),
            credential: credential
        )
        projects = result.projects
        account = saved
    }

    private func loadProjects() async {
        guard let account, projects.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            let (host, token) = try await TokenBroker(store: model.credentials).posthogToken(account.id)
            projects = try await PostHogClient(host: host) { token }.account().projects
        } catch {
            self.error = describe(error)
        }
    }

    private func choose(_ item: PostHogProject) async {
        guard let account else { return }
        busy = true
        defer { busy = false }
        project.posthog = PostHogLink(accountId: account.id, projectId: item.id, projectName: item.displayName, timeZone: item.timezone ?? TimeZone.current.identifier)
        if project.name.isEmpty { project.name = item.displayName }
        // Pick defaults from the events this project really sends; keep the standard ones if the check fails.
        if let seen = try? await seenEvents(account: account, projectId: item.id) {
            let suggested = MetricSettings.suggested(seenEvents: seen)
            project.metrics.newUsers = suggested.newUsers
            project.metrics.extra = suggested.extra
        }
        done()
    }

    private func seenEvents(account: Account, projectId: Int) async throws -> Set<String> {
        let (host, token) = try await TokenBroker(store: model.credentials).posthogToken(account.id)
        let query = PostHogQueries.eventsSeen(
            [MetricSettings.signupEvent, MetricSettings.installEvent],
            since: Date().addingTimeInterval(-30 * 86_400)
        )
        let rows = try await PostHogClient(host: host) { token }.query(projectId: projectId, query, name: "snuffle-defaults")
        return PostHogParsing.eventNames(rows)
    }
}

// MARK: RevenueCat

private struct RevenueCatConnect: View {
    @Binding var project: Project
    var done: () -> Void
    @Environment(AppModel.self) private var model
    @State private var account: Account?
    @State private var key = ""
    @State private var busy = false
    @State private var error: String?
    @State private var projects: [RevenueCatProject] = []

    var body: some View {
        Form {
            ExistingAccounts(platform: .revenueCat, selected: $account)
            if account == nil {
                Section {
                    SecureField("sk_ 开头的 API v2 密钥", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(busy ? "验证中…" : "用这把密钥连接") { Task { await connect() } }
                        .disabled(!key.hasPrefix("sk_") || busy)
                } header: {
                    Text("新密钥")
                } footer: {
                    Text("在 RevenueCat 项目设置 → API keys 新建一把 V2 密钥，权限打开 charts_metrics:overview:read 和 project_configuration:projects:read，其他保持关闭。密钥只存在这台手机的钥匙串里。")
                }
            }
            ErrorText(text: error)
            if !projects.isEmpty {
                Section("选择项目") {
                    ForEach(projects) { item in
                        Button {
                            choose(item)
                        } label: {
                            Text(item.name).foregroundStyle(Palette.ink).frame(minHeight: 44)
                        }
                    }
                }
            }
        }
        .task(id: account?.id) {
            guard let account, projects.isEmpty else { return }
            do {
                guard case .revenueCat(let secret) = try model.credentials.credential(for: account.id) else { return }
                projects = try await RevenueCatClient(secretKey: secret).projects()
            } catch {
                self.error = describe(error)
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
                account: Account(platform: .revenueCat, title: found.map(\.name).joined(separator: "、").ifEmpty("RevenueCat"), subtitle: "密钥 ••••" + secret.suffix(4)),
                credential: .revenueCat(secretKey: secret)
            )
            projects = found
            account = saved
        } catch {
            self.error = describe(error)
        }
    }

    private func choose(_ item: RevenueCatProject) {
        guard let account else { return }
        project.revenueCat = RevenueCatLink(accountId: account.id, projectId: item.id, projectName: item.name)
        if project.metrics.revenue == .none { project.metrics.revenue = .revenueCat }
        if project.name.isEmpty { project.name = item.name }
        done()
    }
}

// MARK: App Store Connect

private struct AppStoreConnect: View {
    @Binding var project: Project
    var done: () -> Void
    @Environment(AppModel.self) private var model
    @State private var account: Account?
    @State private var issuerId = ""
    @State private var keyId = ""
    @State private var pem = ""
    @State private var importing = false
    @State private var busy = false
    @State private var error: String?
    @State private var apps: [AppStoreApp] = []

    var body: some View {
        Form {
            ExistingAccounts(platform: .appStore, selected: $account)
            if account == nil {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Step(number: 1, text: "在 App Store Connect 打开 用户和访问 → 集成 → 团队密钥。")
                        Step(number: 2, text: "生成一把密钥，权限选“客户支持”（只需要读评论和回复评论）。")
                        Step(number: 3, text: "下载 .p8 文件，并记下页面上的 Issuer ID 和密钥 ID。")
                    }
                    .padding(.vertical, 6)
                }
                Section {
                    Button(pem.isEmpty ? "选择 .p8 文件" : "已读取密钥文件 · 重新选择") { importing = true }
                    TextField("密钥 ID，例如 2X9R4HXF34", text: $keyId)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Issuer ID", text: $issuerId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if pem.isEmpty {
                        TextField("或者直接粘贴 .p8 文件内容", text: $pem, axis: .vertical)
                            .lineLimit(3...6)
                            .font(.system(size: 13).monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Button(busy ? "验证中…" : "导入并读取 App 列表") { Task { await connect() } }
                        .disabled(busy || pem.isEmpty || keyId.isEmpty || issuerId.isEmpty)
                } footer: {
                    Text("密钥只存在这台手机的钥匙串里，用来在手机上直接请求 Apple，不经过 Snuffle 的服务器。")
                }
            }
            ErrorText(text: error)
            if !apps.isEmpty {
                Section("选择 App") {
                    ForEach(apps) { app in
                        Button {
                            choose(app)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).foregroundStyle(Palette.ink)
                                Text(app.bundleId).font(.system(size: 12)).foregroundStyle(Palette.ink2)
                            }
                            .frame(minHeight: 44)
                        }
                    }
                }
            }
        }
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
                error = "读不出这个文件，请确认是 Apple 下载的 .p8 密钥"
            }
        }
        .task(id: account?.id) {
            guard let account, apps.isEmpty else { return }
            do {
                guard case .appStoreConnect(let issuer, let key, let pem) = try model.credentials.credential(for: account.id) else { return }
                apps = try await AppStoreConnectClient(token: AppStoreConnectToken(issuerId: issuer, keyId: key, privateKeyPEM: pem)).apps()
            } catch {
                self.error = describe(error)
            }
        }
    }

    private func connect() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let token = try AppStoreConnectToken(issuerId: issuerId, keyId: keyId, privateKeyPEM: pem)
            let found = try await AppStoreConnectClient(token: token).apps()
            let saved = try model.add(
                account: Account(platform: .appStore, title: found.first.map { "\($0.name) 等 \(found.count) 个 App" } ?? "App Store Connect", subtitle: "密钥 \(token.keyId)"),
                credential: .appStoreConnect(issuerId: token.issuerId, keyId: token.keyId, privateKeyPEM: pem)
            )
            apps = found
            account = saved
        } catch {
            self.error = describe(error)
        }
    }

    private func choose(_ app: AppStoreApp) {
        guard let account else { return }
        project.appStore = AppStoreLink(accountId: account.id, appId: app.id, appName: app.name, bundleId: app.bundleId)
        if project.name.isEmpty { project.name = app.name }
        done()
    }
}

private struct Step: View {
    var number: Int
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .heavy))
                .frame(width: 22, height: 22)
                .background(Palette.pill, in: Circle())
            Text(text).font(.system(size: 14))
        }
    }
}

// MARK: Google Play

private struct GooglePlayConnect: View {
    @Binding var project: Project
    var done: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var account: Account?
    @State private var packageName = ""
    @State private var busy = false
    @State private var error: String?

    private var clientId: String? {
        (Bundle.main.object(forInfoDictionaryKey: "SnuffleGoogleClientID") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    var body: some View {
        Form {
            ExistingAccounts(platform: .googlePlay, selected: $account)
            if account == nil {
                Section {
                    if clientId == nil {
                        Text("Google Play 登录还没开放，敬请期待。")
                            .foregroundStyle(Palette.ink2)
                    } else {
                        Button(busy ? "等待授权…" : "用 Google 账号登录") { Task { await signIn() } }
                            .disabled(busy)
                    }
                } footer: {
                    Text("用能打开 Google Play 管理中心的那个 Google 账号登录。只请求读取和回复评论的权限。")
                }
            }
            if account != nil {
                Section {
                    TextField("包名，例如 com.example.app", text: $packageName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button(busy ? "验证中…" : "读取评论确认") { Task { await verify() } }
                        .disabled(busy || !packageName.contains("."))
                } header: {
                    Text("哪个 App")
                } footer: {
                    Text("Google 不提供 App 列表，需要填包名。Google 只返回近 7 天的评论。")
                }
            }
            ErrorText(text: error)
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
            account = try model.add(account: Account(platform: .googlePlay, title: email ?? "Google 账号", subtitle: "Google Play"), credential: .googleOAuth(token))
        } catch let authError as ASWebAuthenticationSessionError where authError.code == .canceledLogin {
            return
        } catch {
            self.error = describe(error)
        }
    }

    private func verify() async {
        guard let account else { return }
        busy = true
        error = nil
        defer { busy = false }
        let name = packageName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let token = try await TokenBroker(store: model.credentials).googleToken(account.id)
            _ = try await GooglePlayClient { token }.reviews(packageName: name, projectId: project.id)
            project.googlePlay = GooglePlayLink(accountId: account.id, packageName: name)
            if project.name.isEmpty { project.name = name }
            done()
        } catch {
            self.error = describe(error)
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
