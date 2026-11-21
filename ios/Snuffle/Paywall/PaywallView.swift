import SnuffleKit
import StoreKit
import SwiftUI

/// Snuffle Pro. Refreshing stays free; Pro adds unlimited projects, widgets and 30-day history (and drafting
/// replies when `Feature.replyDrafts` is on). The top half shows what Pro looks like with the person's own
/// numbers, opened on the page for the feature that brought them here.
struct PaywallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @State private var page: PaywallPage
    @State private var selected = ProStore.yearly
    @State private var buying = false
    @State private var message: String?

    init(reason: PaywallReason) {
        _page = State(initialValue: PaywallPage(reason))
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 12) {
                    header
                    PaywallStage(page: page, entry: previewEntry)
                        .frame(minHeight: 230, maxHeight: .infinity)
                    pagePicker
                    plans.padding(.top, 8)
                    purchaseButton
                    footnote
                    links
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 4)
                .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Palette.paper)
        .presentationDragIndicator(.visible)
        .task {
            if model.pro.products.isEmpty { await model.pro.loadProducts() }
        }
    }

    /// The widget data a Pro person would see, from the projects a refresh reads. Someone with no projects yet
    /// (opened from settings) sees the labelled sample instead.
    private var previewEntry: TodayEntry {
        let entry = TodayEntry.make(projects: model.refreshable, cache: model.cache, unlocked: true, demo: model.settings.demoMode, accent: model.settings.accent)
        return entry.rows.isEmpty ? .placeholder : entry
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Snuffle Pro")
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(0.5)
                    .foregroundStyle(Palette.stripText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Palette.strip, in: Capsule())
                Text(page.headline)
                    .font(.system(size: 25, weight: .heavy))
                    .foregroundStyle(Palette.ink)
                Text(page.subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 44, height: 44)
            }
            .padding(.trailing, -10)
            .padding(.top, -10)
            .accessibilityLabel("关闭")
            .accessibilityIdentifier("closePaywall")
        }
    }

    private var pagePicker: some View {
        HStack(spacing: 4) {
            ForEach(PaywallPage.allCases) { item in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { page = item }
                } label: {
                    Text(item.tab)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(page == item ? Palette.stripText : Palette.ink2)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(page == item ? Palette.strip : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(page == item ? .isSelected : [])
                .accessibilityIdentifier("page-\(item.rawValue)")
            }
        }
        .padding(3)
        .background(Palette.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.line))
    }

    // MARK: Plans

    private var plans: some View {
        HStack(spacing: 8) {
            plan(ProStore.monthly, title: "按月", unit: "每月")
            plan(ProStore.yearly, title: "按年", unit: "每年", badge: model.pro.availableTrialDays.map { "先免费 \($0) 天" })
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
                    .font(Typeface.number(26))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit).font(.system(size: 11)).foregroundStyle(Palette.ink2)
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 88)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(isSelected ? Palette.ink : Palette.line, lineWidth: isSelected ? 2 : 1))
            .overlay(alignment: .top) {
                if let badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Palette.onAccent)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 9)
                        .padding(.vertical, 2)
                        .background(accent, in: Capsule())
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
        .padding(.top, -4)
    }

    private func terms(for product: Product) -> String {
        switch selected {
        case ProStore.yearly:
            let price = "\(product.displayPrice)/年（约 \(model.pro.monthlyEquivalent(of: product))/月）"
            if let days = model.pro.availableTrialDays {
                return "今天不扣费，\(days) 天试用结束前 24 小时取消就不花钱。之后 \(price)，自动续期。"
            }
            return "\(price)，自动续期，到期前 24 小时取消就不再续费。"
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

/// The four things Pro shows off, one page each.
enum PaywallPage: String, CaseIterable, Identifiable {
    case desk, lock, history, projects

    var id: String { rawValue }

    /// Reply drafting is hidden (`Feature.replyDrafts`); its paywall opens on the widgets for now.
    init(_ reason: PaywallReason) {
        switch reason {
        case .history: self = .history
        case .projects: self = .projects
        case .widgets, .general, .drafts: self = .desk
        }
    }

    var tab: String {
        switch self {
        case .desk: "桌面"
        case .lock: "锁屏"
        case .history: "30 天"
        case .projects: "项目"
        }
    }

    var headline: String {
        switch self {
        case .desk: "今天的数字，放上桌面"
        case .lock: "抬手就看到今天涨了多少"
        case .history: "把 7 天拉长到 30 天"
        case .projects: "项目想加多少加多少"
        }
    }

    var subtitle: String {
        switch self {
        case .desk: "不打开 App 也能看，按一下直接刷新"
        case .lock: "锁屏上一眼看完新增和收入"
        case .history: "新增、收入、活跃，每天的走势"
        case .projects: "免费版最多 \(AppModel.freeProjectLimit) 个，Pro 不限，一次刷新全部"
        }
    }
}
