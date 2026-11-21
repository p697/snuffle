import SnuffleKit
import StoreKit
import SwiftUI

/// Snuffle Pro. Refreshing stays free; Pro adds unlimited projects, widgets, 30-day history and (when
/// `Feature.replyDrafts` is on) drafting replies.
struct PaywallView: View {
    var reason: PaywallReason
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @State private var selected = ProStore.yearly
    @State private var buying = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Spacer()
                    Button("恢复购买") { Task { await model.pro.restore(); if model.pro.isPro { dismiss() } } }
                        .font(.system(size: 14, weight: .semibold))
                        .frame(minHeight: 44)
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("关闭")
                }
                .foregroundStyle(Palette.ink)

                HStack(spacing: 16) {
                    ZStack(alignment: .topTrailing) {
                        ZStack(alignment: .top) {
                            PeekingCat(state: CatState(), ready: false, buttonSize: 84)
                            Circle().fill(accent).frame(width: 84, height: 84)
                                .overlay(RefreshArrow().stroke(Palette.onAccent, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)).frame(width: 38, height: 38))
                        }
                        Text("Pro")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(Palette.stripText)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 2)
                            .background(Palette.strip, in: Capsule())
                            .offset(x: 8, y: -4)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Snuffle Pro").font(Typeface.number(40))
                        Text(headline).font(.system(size: 14)).foregroundStyle(Palette.ink2)
                    }
                }

                CardGroup {
                    if Feature.replyDrafts {
                        Benefit(symbol: "sparkles", title: "帮我起草回复", detail: "按评论的语言写好回复，附中文对照，改两句就能发", highlighted: reason == .drafts)
                        Divider().overlay(Palette.line)
                    }
                    Benefit(symbol: "square.stack.3d.up", title: "不限项目", detail: "免费版两个，Pro 想加多少加多少", highlighted: reason == .projects)
                    Divider().overlay(Palette.line)
                    Benefit(symbol: "rectangle.grid.1x2", title: "桌面和锁屏小组件", detail: "不打开 App 也能看数，还能直接刷新", highlighted: reason == .widgets)
                    Divider().overlay(Palette.line)
                    Benefit(symbol: "chart.bar", title: "30 天历史", detail: "免费版看今天和 7 天", highlighted: reason == .history)
                }

                VStack(spacing: 10) {
                    plan(ProStore.monthly, title: "按月", fallback: "$1.99", unit: "每月")
                    plan(ProStore.yearly, title: "按年", fallback: "$19.99", unit: "每年", note: "先免费试 7 天", recommended: true)
                    plan(ProStore.lifetime, title: "买断", fallback: "$29.99", unit: "一次付清")
                }

                if let error {
                    Text(error).font(.system(size: 14)).foregroundStyle(Palette.bad)
                }
                if let loadError = model.pro.loadError, model.pro.products.isEmpty {
                    Text(loadError).font(.system(size: 13)).foregroundStyle(Palette.ink2)
                }

                Button(buying ? "处理中…" : cta) { Task { await buy() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(buying || model.pro.product(selected) == nil)
                    .accessibilityIdentifier("purchase")

                Text(fineprint)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink2)
                HStack(spacing: 16) {
                    Link("使用条款", destination: URL(string: "https://snuffle.ai/terms")!)
                    Link("隐私政策", destination: URL(string: "https://snuffle.ai/privacy")!)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.ink2)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Palette.paper)
        .presentationDragIndicator(.visible)
    }

    private var headline: String {
        switch reason {
        case .drafts: "起草回复是 Pro 功能"
        case .projects: "免费版最多两个项目"
        case .widgets: "小组件是 Pro 功能"
        case .history: "30 天历史是 Pro 功能"
        case .general: "刷新一直免费，Pro 帮你把事办完"
        }
    }

    private var cta: String {
        selected == ProStore.yearly && model.pro.product(ProStore.yearly)?.subscription?.introductoryOffer != nil ? "开始 7 天免费试用" : "继续"
    }

    private var fineprint: String {
        "订阅会自动续期，可随时在 iPhone 设置 → Apple 账户 → 订阅里取消，在当期结束前 24 小时取消就不会续费。按年订阅的免费试用结束后按年扣费。买断只付一次。"
    }

    private func plan(_ id: String, title: String, fallback: String, unit: String, note: String? = nil, recommended: Bool = false) -> some View {
        let product = model.pro.product(id)
        let isSelected = selected == id
        return Button {
            selected = id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 16, weight: .bold))
                        if recommended {
                            Text("推荐").font(.system(size: 11, weight: .heavy)).foregroundStyle(Palette.onAccent)
                                .padding(.horizontal, 6).padding(.vertical, 1).background(accent, in: Capsule())
                        }
                    }
                    if let note { Text(note).font(.system(size: 12)).foregroundStyle(Palette.ink2) }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(product?.displayPrice ?? fallback).font(Typeface.number(24))
                    Text(unit).font(.system(size: 11)).foregroundStyle(Palette.ink2)
                }
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 16)
            .frame(minHeight: 64)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(isSelected ? Palette.ink : Palette.line, lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("plan-\(id)")
    }

    private func buy() async {
        guard let product = model.pro.product(selected) else { return }
        buying = true
        error = nil
        defer { buying = false }
        do {
            if try await model.pro.purchase(product) { dismiss() }
        } catch {
            self.error = "没能完成购买：\(error.localizedDescription)"
        }
    }
}

private struct Benefit: View {
    var symbol: String
    var title: String
    var detail: String
    var highlighted: Bool
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(highlighted ? accent : Palette.pill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .foregroundStyle(highlighted ? Palette.onAccent : Palette.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .bold))
                Text(detail).font(.system(size: 13)).foregroundStyle(Palette.ink2)
            }
        }
        .padding(.vertical, 12)
    }
}
