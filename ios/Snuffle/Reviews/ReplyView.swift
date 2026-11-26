import SnuffleKit
import SwiftUI

/// Writing a public reply. "帮我起草" asks the model for a draft in the reviewer's language with a Chinese rendering
/// (Pro; hidden while `Feature.replyDrafts` is off).
struct ReplyView: View {
    var review: Review
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// This screen is itself a sheet, so it presents the paywall on top of itself.
    @State private var paywall = false
    @State private var text = ""
    @State private var draft: ReplyDraft?
    @State private var drafting = false
    @State private var sending = false
    @State private var confirming = false
    @State private var error: String?

    private var project: Project? { model.projects.first { $0.id == review.projectId } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    original
                    editor
                    if let translation = draft?.translation {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel(draft?.isSample == true ? String(localized: "中文对照 · 示例草稿") : String(localized: "中文对照"))
                            Text(translation)
                                .font(.system(size: 14))
                                .foregroundStyle(Palette.ink2)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }
                    if let error {
                        Text(error).font(.system(size: 14)).foregroundStyle(Palette.bad)
                    }
                    Text(review.platform == .appStore ? "回复会公开显示在 App Store，Apple 审核后才会出现，通常需要一天。" : "回复会公开显示在 Google Play，评论者会收到通知。")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink2)
                }
                .padding(16)
            }
            .background(Palette.paper)
            .navigationTitle("回复")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "发送中…" : "发布") { confirming = true }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                        .accessibilityIdentifier("publishReply")
                }
            }
            .confirmationDialog("公开发布这条回复？", isPresented: $confirming, titleVisibility: .visible) {
                Button("发布到 \(review.platform.displayName)") { Task { await send() } }
                Button("再改改", role: .cancel) {}
            } message: {
                Text("发布后所有人都能在商店里看到。")
            }
            .sheet(isPresented: $paywall) { PaywallView(reason: .drafts) }
        }
    }

    private var original: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Stars(rating: review.rating)
                Spacer()
                Text([review.author, Format.place(review.territory) ?? Format.language(review.language)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink2)
            }
            if let title = review.title, !title.isEmpty {
                Text(title).font(.system(size: 16, weight: .bold))
            }
            Text(review.body).font(.system(size: 15))
            if let details = review.details {
                Text(verbatim: details).font(.system(size: 12)).foregroundStyle(Palette.ink2)
            }
        }
        .padding(16)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(String(localized: "你的回复"))
                Spacer()
                if Feature.replyDrafts { draftButton }
            }
            TextEditor(text: $text)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 160)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.line))
                .accessibilityIdentifier("replyText")
            Text(verbatim: "\(text.count) / \(review.platform == .appStore ? 5970 : 350)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(text.count > (review.platform == .appStore ? 5970 : 350) ? Palette.bad : Palette.ink2)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var draftButton: some View {
        Button {
            Task { await makeDraft() }
        } label: {
            HStack(spacing: 6) {
                if drafting { ProgressView().controlSize(.small) }
                Text(drafting ? "起草中…" : "帮我起草")
                if !model.pro.isPro && !model.settings.demoMode {
                    Text(verbatim: "Pro").font(.system(size: 11, weight: .heavy)).padding(.horizontal, 6).padding(.vertical, 1).background(Palette.ink, in: Capsule()).foregroundStyle(Palette.paper)
                }
            }
            .font(.system(size: 14, weight: .bold))
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(drafting)
        .accessibilityIdentifier("draftReply")
    }

    private func makeDraft() async {
        guard model.pro.isPro || model.settings.demoMode else {
            paywall = true
            return
        }
        drafting = true
        error = nil
        defer { drafting = false }
        do {
            let result = try await model.draftReply(for: review)
            draft = result
            text = result.reply
        } catch CloudError.proRequired(let message) {
            // Already Pro here but refused by the server (e.g. shared on too many devices): say why, don't upsell.
            if model.pro.isPro { error = message } else { paywall = true }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func send() async {
        sending = true
        error = nil
        defer { sending = false }
        do {
            try await model.reply(to: review, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
            Analytics.reviewReplyResolved(review.platform, error: nil)
            dismiss()
        } catch {
            Analytics.reviewReplyResolved(review.platform, error: error)
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
