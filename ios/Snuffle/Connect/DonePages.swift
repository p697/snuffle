import SnuffleKit
import SwiftUI

// Right after a source is connected, the page shows what it just read, so the person sees it working before moving on.

/// RevenueCat's overview straight after the key was accepted, and which side the home screen counts revenue from.
struct RevenueCatDonePage: View {
    @Environment(ConnectSession.self) private var session
    @Environment(AppModel.self) private var model
    var next: () -> Void
    @State private var overview: SubscriptionOverview?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SuccessBadge(text: String(localized: "密钥没问题"))
                SourceHeader(platform: .revenueCat, title: String(localized: "RevenueCat 连上了"), subtitle: String(localized: "\(session.project.revenueCat?.projectName ?? "") · 刚刚读到"))
                numbers
                if session.project.posthog != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("首页的收入用哪边的数").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
                        ChoiceBar(options: [(.posthog, "PostHog 付费事件"), (.revenueCat, "RevenueCat")], selection: revenueChoice)
                        Text("RevenueCat 含续订，更接近实际到账；PostHog 能看到每一笔订单。")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink2)
                    }
                    .padding(18)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                ErrorText(text: error)
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) { ContinueBar(action: next) }
        .sheetPage()
        .task {
            defer { loading = false }
            do {
                overview = try await model.provider.overview(for: session.probe(.revenueCat))
            } catch {
                self.error = String(localized: "连上了，但这次没读到数字：\(describe(error))")
            }
        }
    }

    private var numbers: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 20) {
            GridRow {
                Metric(label: "月经常性收入", value: overview?.mrr.map { Format.money($0) }, loading: loading, highlighted: true)
                Metric(label: "在订人数", value: overview?.activeSubscriptions.map(Format.number), loading: loading)
            }
            GridRow {
                Metric(label: "试用中", value: overview?.activeTrials.map(Format.number), loading: loading)
                Metric(label: "近 28 天收入", value: overview?.revenueLast28Days.map { Format.money($0) }, loading: loading)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private enum RevenueChoice: Hashable { case posthog, revenueCat }

    private var revenueChoice: Binding<RevenueChoice> {
        Binding {
            session.project.metrics.revenue == .revenueCat ? .revenueCat : .posthog
        } set: { choice in
            session.project.metrics.revenue = choice == .revenueCat ? .revenueCat : .posthogEvent(event: "purchase", valueProperty: "value")
        }
    }
}

/// One labelled number on a done page; rolls while loading.
private struct Metric: View {
    var label: LocalizedStringKey
    var value: String?
    var loading: Bool
    var highlighted = false
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13)).foregroundStyle(Palette.ink2)
            Odometer(text: value ?? "–", size: 40)
                .opacity(loading && value == nil ? 0.35 : 1)
                .padding(.horizontal, 2)
                .background(alignment: .bottomLeading) {
                    if highlighted && !loading && value != nil {
                        Rectangle().fill(accent).frame(height: 14).padding(.bottom, 2)
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A store straight after connecting: how many reviews wait for a reply and the newest one, plus switching apps.
struct StoreDonePage: View {
    @Environment(ConnectSession.self) private var session
    @Environment(AppModel.self) private var model
    var platform: Platform
    var next: () -> Void
    @State private var result: RefreshResult?
    @State private var loading = true
    @State private var showAll = false
    /// The App Store app whose storefronts were looked for, so an app on none is not looked for again.
    @State private var probed: String?
    @State private var pickingCountries = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SuccessBadge(text: badge)
                SourceHeader(platform: platform, title: String(localized: "\(platform.displayName) 连上了"), subtitle: String(localized: "已选 \(appName)"))
                reviewsCard
                if platform == .appStore { countriesCard }
                if !keyless, apps.count > 1 { switcher }
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) { ContinueBar(action: next) }
        .sheetPage()
        .task(id: readKey) { await load() }
        .sheet(isPresented: $pickingCountries) {
            CountryPicker(selection: Binding(
                get: { session.project.appStore?.countries ?? [] },
                set: { session.project.appStore?.countries = $0 }
            ))
        }
    }

    /// Read without a key: the rating and the public reviews, no replies.
    private var keyless: Bool { platform == .appStore && session.project.appStore?.hasKey == false }

    private var countries: [String] { session.project.appStore?.countries ?? [] }

    /// Reads again when the app or its storefronts change.
    private var readKey: String { appKey + "|" + countries.joined(separator: ",") }

    private var badge: String {
        if keyless { return String(localized: "不用密钥 · 读公开的评分和评论") }
        return platform == .appStore ? String(localized: "密钥没问题 · 读到 \(session.appStoreApps.count) 个 App") : String(localized: "已登录 · \(session.googleApps.count) 个 App")
    }

    private var appName: String {
        platform == .appStore ? session.project.appStore?.appName ?? "" : session.googleApps.first { $0.packageName == session.project.googlePlay?.packageName }?.displayName ?? session.project.googlePlay?.packageName ?? ""
    }

    private var appKey: String { platform == .appStore ? session.project.appStore?.appId ?? "" : session.project.googlePlay?.packageName ?? "" }

    private var apps: [(id: String, name: String, detail: String)] {
        platform == .appStore
            ? session.appStoreApps.map { ($0.id, $0.name, $0.bundleId) }
            : session.googleApps.map { ($0.packageName, $0.displayName, $0.packageName) }
    }

    private var reviews: [Review] { (result?.reviews[platform] ?? []).sorted { $0.createdAt > $1.createdAt } }

    private var reviewsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if keyless {
                    Odometer(text: result?.snapshot[.rating].map(Format.rating) ?? "–", size: 56)
                        .opacity(loading && result == nil ? 0.35 : 1)
                    Text("App Store 评分").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
                } else {
                    Odometer(text: result?.snapshot.reviewsToAnswer.map(Format.number) ?? "–", size: 56)
                        .opacity(loading && result == nil ? 0.35 : 1)
                    Text("条评论待回复").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
                }
                Spacer(minLength: 4)
                if !loading, !reviews.isEmpty {
                    Text(platform == .googlePlay ? "近 7 天 \(reviews.count) 条" : "读到 \(reviews.count) 条")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink2)
                }
            }
            if let latest = reviews.first {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Stars(rating: latest.rating)
                        Spacer()
                        Text([latest.author, Format.place(latest.territory) ?? Format.language(latest.language), Format.ago(latest.createdAt)].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink2)
                            .lineLimit(1)
                    }
                    if let title = latest.title, !title.isEmpty {
                        Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
                    }
                    Text(latest.body).font(.system(size: 14)).foregroundStyle(Palette.ink2).lineLimit(2)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.pill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if !loading {
                Text(platform == .googlePlay ? "近 7 天还没有新评论，有了会出现在评论页。" : "还没有评论，有了会出现在评论页。")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.ink2)
            }
        }
        .padding(18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// Where the rating, and without a key the reviews, are read.
    private var countriesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(keyless ? String(localized: "读这些地区的评分和评论") : String(localized: "读这些地区的评分"))
            VStack(alignment: .leading, spacing: 12) {
                if countries.isEmpty {
                    Text(loading ? "正在找 App 在哪些地区有评分…" : "在 App Store 上还没找到这个 App。已经上架的话，自己选地区。")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.ink2)
                } else {
                    FlowLayout(spacing: 8) {
                        ForEach(countries, id: \.self) { code in
                            Text(verbatim: Format.place(code) ?? code.uppercased())
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Palette.ink)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Palette.pill, in: Capsule())
                        }
                    }
                }
                if !loading || !countries.isEmpty {
                    Button(countries.isEmpty ? "选择地区" : "修改地区") { pickingCountries = true }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Palette.ink)
                        .frame(minHeight: 36)
                        .accessibilityIdentifier("pickCountries")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private var switcher: some View {
        let shown = showAll ? apps : Array(apps.prefix(3))
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(String(localized: "不是这个 App？换一个"))
            CardGroup {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { RowDivider() }
                    Button {
                        choose(app.id)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
                                Text(app.detail).font(.system(size: 12)).foregroundStyle(Palette.ink2)
                            }
                            Spacer()
                            Circle()
                                .strokeBorder(app.id == appKey ? Palette.ink : Palette.faint, lineWidth: app.id == appKey ? 7 : 2)
                                .frame(width: 22, height: 22)
                        }
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(app.id == appKey ? .isSelected : [])
                }
                if !showAll && apps.count > 3 {
                    RowDivider()
                    Button("还有 \(apps.count - 3) 个") { showAll = true }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink2)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                }
            }
        }
    }

    private func choose(_ id: String) {
        guard id != appKey else { return }
        if platform == .appStore, let app = session.appStoreApps.first(where: { $0.id == id }), let link = session.project.appStore {
            session.project.appStore = AppStoreLink(accountId: link.accountId, appId: app.id, appName: app.name, bundleId: app.bundleId)
            probed = nil
        } else if platform == .googlePlay, let link = session.project.googlePlay {
            session.project.googlePlay = GooglePlayLink(accountId: link.accountId, packageName: id)
        }
    }

    /// An App Store app is first looked for in the large storefronts, once, to read it where it has the most ratings;
    /// the storefronts found read it again.
    private func load() async {
        loading = true
        defer { loading = false }
        if platform == .appStore, let link = session.project.appStore, link.countries.isEmpty, probed != link.appId {
            probed = link.appId
            let found = await PublicAppStoreClient().storefronts(appId: link.appId, candidates: PublicAppStoreClient.candidates(region: Locale.current.region?.identifier))
            guard !Task.isCancelled, session.project.appStore?.appId == link.appId else { return }
            if !found.isEmpty {
                session.project.appStore?.countries = found
                return
            }
        }
        let probe = session.probe(platform)
        result = await model.provider.refresh(probe, metrics: Set(CardLayout.standard(for: probe).metrics), previous: nil)
    }
}

/// The "继续" button pinned above the home indicator.
private struct ContinueBar: View {
    var action: () -> Void

    var body: some View {
        Button("继续", action: action)
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("continue")
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .background(Palette.paper.opacity(0.95))
    }
}
