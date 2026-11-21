import SnuffleKit
import SwiftUI

/// 评论: every store review across projects, unanswered first.
struct ReviewsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = Filter.toAnswer
    @State private var replying: Review?

    enum Filter: String, CaseIterable, Identifiable {
        case toAnswer = "待回复"
        case all = "全部"
        var id: String { rawValue }
    }

    private var reviews: [Review] {
        let all = model.allReviews
        return filter == .toAnswer ? all.filter(\.needsReply) : all
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ScreenTitle(title: "评论", subtitle: subtitle)
                    Picker("显示", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if reviews.isEmpty {
                        empty
                    }
                    ForEach(reviews) { review in
                        ReviewCard(review: review, project: model.projects.first { $0.id == review.projectId }) {
                            replying = review
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(Palette.paper)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.refreshAll() }
            .sheet(item: $replying) { review in
                ReplyView(review: review)
            }
        }
    }

    private var subtitle: String {
        let toAnswer = model.allReviews.filter(\.needsReply).count
        let stores = Set(model.projects.flatMap { [$0.appStore != nil ? Platform.appStore : nil, $0.googlePlay != nil ? .googlePlay : nil].compactMap { $0 } })
        var parts = ["\(toAnswer) 条待回复"]
        if stores.contains(.appStore) { parts.append("App Store 最近 200 条") }
        if stores.contains(.googlePlay) { parts.append("Google Play 近 7 天") }
        return parts.joined(separator: " · ")
    }

    private var hasStore: Bool { model.projects.contains(where: \.hasStore) }

    private var empty: some View {
        VStack(spacing: 8) {
            Text(!hasStore ? "还没有连接商店" : filter == .all ? "还没有评论" : "都回复完了")
                .font(.system(size: 17, weight: .bold))
            Text(!hasStore ? "在项目里连接 App Store Connect 或 Google Play，评论会汇总到这里，可以直接回复。"
                 : filter == .all ? (model.projects.contains { $0.googlePlay != nil } ? "Google Play 只提供近 7 天的评论。新的评论会在刷新后出现在这里。" : "新的评论会在刷新后出现在这里。")
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
            } else {
                Button(action: onReply) {
                    Text("回复")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Palette.paper)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Palette.ink, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("reply-\(review.storeId)")
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
        .accessibilityLabel("\(rating) 星")
    }
}
