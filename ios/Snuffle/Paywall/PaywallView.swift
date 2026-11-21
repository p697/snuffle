import SnuffleKit
import StoreKit
import SwiftUI

/// Snuffle Pro. Refreshing stays free; Pro adds unlimited projects, 30-day history and widgets (and drafting
/// replies when `Feature.replyDrafts` is on). A poster of the three in giant figures, the one that brought the
/// person here first and inverted, over a panel with the plans.
struct PaywallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var colorScheme
    @State private var selected = ProStore.yearly
    @State private var buying = false
    @State private var message: String?
    @State private var cat = CatState()
    private let focus: ProPerk?

    /// Room above the panel for the cat's head once it is out.
    private static let catHeadroom: CGFloat = 84

    init(reason: PaywallReason) {
        focus = ProPerk(reason)
    }

    private var colors: PosterColors { PosterColors(accent: accent, scheme: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geometry in
                poster(height: geometry.size.height)
            }
            .padding(.top, 8)
            .padding(.bottom, Self.catHeadroom)
            panel
        }
        .background(colors.fill.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .task {
            if model.pro.products.isEmpty { await model.pro.loadProducts() }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(350))
            cat = CatState(out: true)
        }
    }

    // MARK: Poster

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(colors.ink)
                .frame(width: 24, height: 24)
                .overlay(RefreshArrow().stroke(colors.fill, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)).frame(width: 14, height: 14))
                .accessibilityHidden(true)
            Text("Snuffle Pro")
                .font(.system(size: 17, weight: .heavy))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 44, height: 44)
            }
            .padding(.trailing, -14)
            .accessibilityLabel("关闭")
            .accessibilityIdentifier("closePaywall")
        }
        .foregroundStyle(colors.ink)
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }

    /// Three ruled rows, their figures as large as the height allows (96 pt on a 6.1" phone).
    private func poster(height: CGFloat) -> some View {
        let perks = ProPerk.ordered(first: focus)
        let size = min(96, max(36, (height - 2) / CGFloat(perks.count) - 18))
        return VStack(spacing: 0) {
            ForEach(perks, id: \.self) { perk in
                row(perk, size: size)
            }
            Rectangle().fill(colors.ink).frame(height: 2)
        }
        .padding(.horizontal, 24)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ perk: ProPerk, size: CGFloat) -> some View {
        let focused = perk == focus
        return HStack(alignment: .bottom, spacing: 12) {
            Group {
                if let figure = perk.figure {
                    Text(figure).font(Typeface.number(size))
                } else {
                    Image(systemName: "infinity").font(.system(size: size * 0.74, weight: .black))
                }
            }
            .fixedSize()
            // The line box of a figure this large is mostly air; the row only keeps the digits' height.
            .frame(height: size * 0.84)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(perk.label)
                    .font(.system(size: min(19, max(15, size * 0.2)), weight: .heavy))
                Text(perk.note)
                    .font(.system(size: 13, weight: .semibold))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.bottom, size * 0.06)
        }
        // Small phones shrink the figures; the rows tighten with them.
        .padding(.vertical, size < 60 ? 4 : 8)
        .padding(.horizontal, focused ? 12 : 0)
        .foregroundStyle(focused ? colors.fill : colors.ink)
        .background(focused ? colors.ink : .clear)
        .padding(.horizontal, focused ? -12 : 0)
        .overlay(alignment: .top) { Rectangle().fill(colors.ink).frame(height: 2) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(perk.spoken)，\(perk.note)")
        .accessibilityIdentifier("perk-\(perk.rawValue)")
        .accessibilityAddTraits(focused ? .isSelected : [])
    }

    // MARK: Panel

    private var panel: some View {
        VStack(spacing: 0) {
            Text("刷新永远免费。上面三样，开了 Pro 就有。")
                .font(.system(size: 14))
                .foregroundStyle(Palette.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            plans.padding(.top, 22)
            purchaseButton.padding(.top, 14)
            footnote.padding(.top, 8)
            links
        }
        .padding(.horizontal, 20)
        .padding(.top, 30)
        .padding(.bottom, 4)
        .catPanel(cat)
    }

    private var plans: some View {
        HStack(spacing: 8) {
            plan(ProStore.monthly, title: "按月", unit: "每月")
            plan(ProStore.yearly, title: "按年", unit: model.pro.product(ProStore.yearly).map { "每月约 \(model.pro.monthlyEquivalent(of: $0))" } ?? "每年", badge: model.pro.availableTrialDays.map { "先免费 \($0) 天" })
            plan(ProStore.lifetime, title: "买断", unit: "一次付清")
        }
    }

    private func plan(_ id: String, title: String, unit: String, badge: String? = nil) -> some View {
        let isSelected = selected == id
        return Button {
            selected = id
            message = nil
        } label: {
            VStack(spacing: 4) {
                Text(title).font(.system(size: 13, weight: .bold))
                Text(model.pro.product(id)?.displayPrice ?? "—")
                    .font(Typeface.number(28))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit).font(.system(size: 11.5)).foregroundStyle(Palette.ink2).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(isSelected ? Palette.ink : Palette.line, lineWidth: isSelected ? 2 : 1))
            .overlay(alignment: .top) {
                if let badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(colors.fill)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 9)
                        .padding(.vertical, 2)
                        .background(colors.ink, in: Capsule())
                        .offset(y: -10)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("plan-\(id)")
    }

    // MARK: Purchase

    private var selectedProduct: Product? { model.pro.product(selected) }

    private var purchaseButton: some View {
        Button(buying ? "处理中…" : callToAction) { Task { await buy() } }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(buying || selectedProduct == nil)
            .opacity(selectedProduct == nil ? 0.35 : 1)
            .accessibilityIdentifier("purchase")
    }

    private var callToAction: String {
        guard let product = selectedProduct else { return model.pro.loadError == nil ? "正在获取价格…" : "继续" }
        switch selected {
        case ProStore.yearly:
            if let days = model.pro.availableTrialDays { return "免费试用 \(days) 天" }
            return "订阅 · \(product.displayPrice)/年"
        case ProStore.monthly: return "订阅 · \(product.displayPrice)/月"
        default: return "买断 · \(product.displayPrice)"
        }
    }

    /// What the selected plan costs and when, right under the button. Errors take its place.
    private var footnote: some View {
        Group {
            if let message {
                Text(message).foregroundStyle(Palette.bad)
            } else if model.pro.products.isEmpty, model.pro.loadError != nil {
                HStack(spacing: 2) {
                    Text("没连上 App Store，价格还没加载出来")
                    Button("重试") { Task { await model.pro.loadProducts() } }
                        .font(.system(size: 12.5, weight: .heavy))
                        .foregroundStyle(Palette.ink)
                        .underline()
                        .frame(minHeight: 34)
                        .accessibilityIdentifier("retryPrices")
                }
            } else if let product = selectedProduct {
                Text(terms(for: product))
            } else {
                Text(" ")
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Palette.ink2)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 34)
    }

    private func terms(for product: Product) -> String {
        switch selected {
        case ProStore.yearly:
            if let days = model.pro.availableTrialDays {
                return "今天不扣费，\(days) 天试用结束前 24 小时取消就不花钱。之后 \(product.displayPrice)/年，自动续期。"
            }
            return "\(product.displayPrice)/年，自动续期，到期前 24 小时取消就不再续费。"
        case ProStore.monthly:
            return "\(product.displayPrice)/月，自动续期，到期前 24 小时取消就不再续费。"
        default:
            return "只付一次 \(product.displayPrice)，一直能用，不会续费。"
        }
    }

    private var links: some View {
        HStack(spacing: 18) {
            Button("恢复购买") { Task { await restore() } }
                .accessibilityIdentifier("restorePurchases")
            Link("使用条款", destination: URL(string: "https://snuffle.ai/terms")!)
            Link("隐私政策", destination: URL(string: "https://snuffle.ai/privacy")!)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Palette.ink2)
        .frame(maxWidth: .infinity, minHeight: 32)
    }

    private func buy() async {
        guard let product = selectedProduct else { return }
        buying = true
        message = nil
        defer { buying = false }
        do {
            if try await model.pro.purchase(product) { dismiss() }
        } catch {
            message = "没能完成购买：\(error.localizedDescription)"
        }
    }

    private func restore() async {
        message = nil
        await model.pro.restore()
        if model.pro.isPro { dismiss() } else { message = "这个 Apple 账户下没有找到可以恢复的购买" }
    }
}

/// What Pro adds, one poster row each.
enum ProPerk: String, CaseIterable {
    case projects, history, widgets

    /// Reply drafting is hidden (`Feature.replyDrafts`), so its paywall highlights no row for now.
    init?(_ reason: PaywallReason) {
        switch reason {
        case .projects: self = .projects
        case .history: self = .history
        case .widgets: self = .widgets
        case .general, .drafts: return nil
        }
    }

    /// The row that brought the person here goes first.
    static func ordered(first: ProPerk?) -> [ProPerk] {
        guard let first else { return allCases }
        return [first] + allCases.filter { $0 != first }
    }

    /// The giant figure; unlimited projects draw the infinity symbol instead.
    var figure: String? {
        switch self {
        case .projects: nil
        case .history: "30"
        // The widget families in SnuffleWidgets.swift: two on the home screen, two on the lock screen.
        case .widgets: "4"
        }
    }

    var label: String {
        switch self {
        case .projects: "个项目"
        case .history: "天走势"
        case .widgets: "款小组件"
        }
    }

    /// What the free version gives instead.
    var note: String {
        switch self {
        case .projects: "免费版最多 \(AppModel.freeProjectLimit) 个"
        case .history: "免费版看 7 天"
        case .widgets: "桌面、锁屏各 2 款，免费版没有"
        }
    }

    var spoken: String {
        switch self {
        case .projects: "项目不限"
        case .history: "30 天走势"
        case .widgets: "4 款小组件"
        }
    }
}
