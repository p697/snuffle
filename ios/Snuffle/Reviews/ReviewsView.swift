import SnuffleKit
import SwiftUI

/// 评论: every store review across projects, unanswered first.
struct ReviewsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = Filter.toAnswer
    @State private var replying: Review?
    /// A project whose App Store is read without a key, being given one to reply with.
    @State private var addingKey: Project?

    enum Filter: CaseIterable, Identifiable {
        case toAnswer, all
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .toAnswer: "待回复"
            case .all: "全部"
            }
        }
    }

    private var reviews: [Review] {
        let all = model.allReviews
        return filter == .toAnswer && answers ? all.filter(\.needsReply) : all
    }

    /// Whether any store says which reviews wait for a reply; without one there is nothing to filter by.
    private var answers: Bool { model.projects.contains(where: \.answersReviews) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ScreenTitle(title: String(localized: "评论"), subtitle: subtitle)
                    if answers {
                        Picker("显示", selection: $filter) {
                            ForEach(Filter.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    if reviews.isEmpty {
                        empty
                    }
                    ForEach(reviews) { review in
                        let project = model.projects.first { $0.id == review.projectId }
                        ReviewCard(review: review, project: project) {
                            if review.canReply { replying = review } else { addingKey = project }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .clearsTabBar()
            .background(Palette.paper)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.refreshAll() }
            .sheet(item: $replying) { review in
                ReplyView(review: review)
            }
            .sheet(item: $addingKey) { project in
                ReconnectSheet(project: project, platform: .appStore)
            }
        }
    }

    private var subtitle: String {
        let toAnswer = model.allReviews.filter(\.needsReply).count
        let projects = model.projects
        var parts: [String] = []
        if answers { parts.append(String(localized: "\(toAnswer) 条待回复")) }
        if projects.contains(where: { $0.appStore?.hasKey == true }) { parts.append(String(localized: "App Store 最近 200 条")) }
        if projects.contains(where: { $0.appStore?.hasKey == false }) { parts.append(String(localized: "App Store 各地区最近 50 条")) }
        if projects.contains(where: { $0.googlePlay != nil }) { parts.append(String(localized: "Google Play 连接以来")) }
        return parts.joined(separator: " · ")
    }

    private var hasStore: Bool { model.projects.contains(where: \.hasStore) }

    private var empty: some View {
        VStack(spacing: 8) {
            Text(!hasStore ? "还没有连接商店" : filter == .all || !answers ? "还没有评论" : "都回复完了")
                .font(.system(size: 17, weight: .bold))
            Text(!hasStore ? "在项目里连接 App Store Connect 或 Google Play，评论会汇总到这里，可以直接回复。"
                 : filter == .all || !answers ? (model.projects.contains { $0.googlePlay != nil } ? "Google Play 只提供近 7 天的评论，Snuffle 会把读到的留下来。新的评论会在刷新后出现在这里。" : "新的评论会在刷新后出现在这里。")
                 : "新的评论会在下次刷新时出现在这里。")
                .font(.system(size: 14))
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct ReviewCard: View {
    var review: Review
    var project: Project?
    var onReply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let project { ProjectBadge(project: project, size: 22) }
                Stars(rating: review.rating)
                Spacer()
                Text(review.platform.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
            }
            if let title = review.title, !title.isEmpty {
                Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.ink)
            }
            Text(review.body)
                .font(.system(size: 15))
                .foregroundStyle(Palette.ink)
                .lineLimit(5)
            Text(meta)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink2)
            if let details = review.details {
                Text(verbatim: details)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink2)
            }
            if let reply = review.reply {
                VStack(alignment: .leading, spacing: 4) {
                    Text(reply.pending ? "你的回复 · 审核中" : "你的回复")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(reply.pending ? Palette.ink2 : Palette.up)
                    Text(reply.text).font(.system(size: 14)).foregroundStyle(Palette.ink2).lineLimit(3)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.pill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if review.canReply {
                Button(action: onReply) {
                    Text("回复")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Palette.paper)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Palette.ink, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("reply-\(review.storeId)")
            } else {
                // Read without a key: whether it was answered is unknown, and answering takes a key.
                HStack(spacing: 10) {
                    Text("没导入密钥，看不到是否回复过")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: onReply) {
                        Text("导入密钥")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .overlay(Capsule().strokeBorder(Palette.ink, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("addKey-\(review.storeId)")
                }
            }
        }
        .padding(16)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var meta: String {
        [
            review.author,
            Format.place(review.territory) ?? Format.language(review.language),
            Format.ago(review.createdAt),
            project?.name
        ].compactMap { $0 }.joined(separator: " · ")
    }

}

extension Review {
    /// What a review was written on: "v3.4.1 · Samsung Galaxy S23 · Android 14 · 12 人觉得有用" on Google Play, the
    /// version for an App Store review read without a key.
    var details: String? {
        let parts = [
            appVersion.map { "v" + $0 },
            device,
            system,
            helpful.flatMap { $0 > 0 ? String(localized: "\($0) 人觉得有用") : nil }
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct Stars: View {
    var rating: Int

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { index in
                Image(systemName: index <= rating ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .bold))
            }
        }
        .foregroundStyle(rating <= 2 ? Palette.bad : Palette.ink)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "\(rating) 星"))
    }
}
