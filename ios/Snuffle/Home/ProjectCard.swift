import SnuffleKit
import SwiftUI

/// One project on the home screen. Every row has a fixed height so nothing moves while refreshing:
/// progress, deltas and failures only fill slots that are always there.
struct ProjectCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var colorScheme
    var project: Project
    /// Numbers for a project that is not saved yet (the connect flow's "连上了" page); nil on the home screen.
    var preview: ProjectSnapshot?
    var previewLoading = false

    private var isPreview: Bool { preview != nil || previewLoading }
    private var snapshot: ProjectSnapshot? { preview ?? model.snapshot(project.id) }
    private var stage: CardStage { previewLoading ? .loading : model.stage(project.id) }
    private var mark: SnapshotChange? { model.marks[project.id] }
    private var marked: Bool { mark != nil && !model.marksFading }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    numberRow
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(1)
                        .frame(height: 18)
                }
                Spacer(minLength: 0)
                if project.posthog != nil {
                    HourBars(values: snapshot?.hourlyNewUsers ?? [])
                        .frame(width: 104, height: 44)
                }
            }
            pills
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(failed ? Palette.badLine : .clear, lineWidth: 2)
        }
        .shadow(color: Palette.shadow.opacity(stage == .loading ? (colorScheme == .dark ? 0.6 : 0.18) : 0), radius: 17, y: 16)
        .scaleEffect(stage == .loading ? 1.025 : 1)
        .opacity(stage == .waiting ? 0.42 : 1)
        .zIndex(stage == .loading ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: stage)
        .modifier(Shake.Driver(trigger: model.shakes[project.id] ?? 0))
        .overlay {
            if !isPreview, model.isLocked(project) { LockedOverlay() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("card-\(project.name)")
    }

    private var failed: Bool { !(snapshot?.failures.isEmpty ?? true) && stage != .loading }

    private var header: some View {
        HStack(spacing: 10) {
            ProjectBadge(project: project, size: 28)
            Text(project.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            stateLabel
        }
        .frame(height: 28)
    }

    @ViewBuilder
    private var stateLabel: some View {
        if let failure = snapshot?.failures.first, stage != .loading {
            Button {
                Task { await model.refresh([project]) }
            } label: {
                Text("\(failure.platform.displayName) 没连上 · 重试")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.bad)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(failure.message)
        } else if let online = snapshot?.online {
            HStack(spacing: 6) {
                Circle().fill(online > 0 ? Palette.up : Palette.faint).frame(width: 7, height: 7)
                Text("\(Format.number(online)) 人在线")
            }
            .font(.system(size: 13))
            .foregroundStyle(Palette.ink2)
        }
    }

    private var numberRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Odometer(
                text: snapshot?.headline(for: project).map(Format.number) ?? "–",
                size: 56,
                spinning: stage == .loading,
                color: marked && colorScheme == .dark ? accent : Palette.ink
            )
            .padding(.horizontal, 2)
            .background(alignment: .bottomLeading) {
                // The highlighter: sweeps in left to right, retracts right to left.
                Rectangle()
                    .fill(colorScheme == .dark ? .clear : accent)
                    .frame(height: 20)
                    .scaleEffect(x: marked ? 1 : 0, anchor: model.marksFading ? .trailing : .leading)
                    .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: marked ? 0.28 : 0.4), value: marked)
                    .padding(.bottom, 3)
            }
            .modifier(SettleFlash(trigger: model.settles[project.id] ?? 0))
            .layoutPriority(1)
            DeltaChip(text: mark.flatMap(chipText), visible: marked, size: 14)
        }
        .frame(height: 54, alignment: .bottomLeading)
    }

    /// "+48" for new users, "+$300" for a sale, "+1" for a new review on a store-only card.
    private func chipText(_ change: SnapshotChange) -> String? {
        if project.posthog == nil { return change.reviews > 0 ? "+\(change.reviews)" : nil }
        if change.newUsers > 0 { return Format.delta(users: change.newUsers) }
        if change.revenue > 0 { return Format.delta(money: change.revenue) }
        return nil
    }

    private var subtitle: String {
        guard project.posthog != nil else {
            let stores = [project.appStore != nil ? "App Store" : nil, project.googlePlay != nil ? "Google Play" : nil].compactMap { $0 }
            return "条评论待回复 · " + stores.joined(separator: " + ")
        }
        var text = "今日新增用户"
        if let yesterday = snapshot?.newUsersYesterday { text += " · 昨天此时 \(Format.number(yesterday))" }
        return text
    }

    private var pills: some View {
        HStack(spacing: 6) {
            if let revenuePill { Pill(text: revenuePill, hot: marked && (mark?.hasSale ?? false)) }
            if let extra = snapshot?.extra { Pill(text: "\(Format.number(extra.value)) \(extra.label)") }
            if let reviews = snapshot?.reviewsToAnswer, project.hasStore, project.posthog != nil { Pill(text: "\(reviews) 条评论待回复") }
        }
        .frame(height: 28, alignment: .leading)
        .clipped()
    }

    private var revenuePill: String? {
        guard project.metrics.revenue != .none else { return nil }
        guard let revenue = snapshot?.revenue, revenue > 0 else { return "还没有收入" }
        if let sales = snapshot?.sales { return "\(Format.money(revenue)) · \(sales) 笔" }
        return "\(Format.money(revenue)) · RevenueCat"
    }
}

struct Pill: View {
    var text: String
    var hot = false
    @Environment(\.accent) private var accent

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(hot ? Palette.onAccent : Palette.ink)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(hot ? accent : Palette.pill, in: Capsule())
            .animation(.easeOut(duration: 0.3), value: hot)
    }
}

/// "+48" in a slot that always takes its space, so showing it never moves anything.
struct DeltaChip: View {
    var text: String?
    var visible: Bool
    var size: CGFloat
    @Environment(\.accent) private var accent
    @State private var lastText = ""

    var body: some View {
        Text(text ?? lastText)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, size * 0.55)
            .padding(.vertical, 2)
            .background(accent, in: Capsule())
            .scaleEffect(visible && text != nil ? 1 : 0.6)
            .opacity(visible && text != nil ? 1 : 0)
            .animation(visible ? .spring(response: 0.22, dampingFraction: 0.5) : .easeIn(duration: 0.4), value: visible)
            .onChange(of: text) { _, new in if let new { lastText = new } }
            .accessibilityHidden(!(visible && text != nil))
    }
}

/// New users per hour of today; the current hour in ink, the rest faint.
struct HourBars: View {
    var values: [Int]

    var body: some View {
        Canvas { context, size in
            let slots = 17
            let shown = Array(values.suffix(slots))
            let peak = max(1, shown.max() ?? 1)
            let step = size.width / CGFloat(slots)
            for (index, value) in shown.enumerated() {
                let x = step * (CGFloat(index) + 0.5)
                let height = max(2, size.height * CGFloat(value) / CGFloat(peak))
                var bar = Path()
                bar.move(to: CGPoint(x: x, y: size.height))
                bar.addLine(to: CGPoint(x: x, y: size.height - height))
                let isNow = index == shown.count - 1
                context.stroke(bar, with: .color(isNow ? Palette.ink : Palette.faint), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            for index in shown.count..<slots {
                let x = step * (CGFloat(index) + 0.5)
                var dot = Path()
                dot.move(to: CGPoint(x: x, y: size.height))
                dot.addLine(to: CGPoint(x: x, y: size.height - 2))
                context.stroke(dot, with: .color(Palette.line), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
        }
        .accessibilityLabel("今天每小时新增用户")
    }
}

struct Shake: GeometryEffect {
    var trigger: Int
    var animatableData: CGFloat

    init(trigger: Int) {
        self.trigger = trigger
        animatableData = CGFloat(trigger)
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let progress = animatableData - animatableData.rounded(.down)
        let offset = sin(progress * .pi * 2) * 6 * (progress == 0 ? 0 : 1)
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}

extension Shake {
    /// Drives the shake with a short animation whenever the trigger changes.
    struct Driver: ViewModifier {
        var trigger: Int
        func body(content: Content) -> some View {
            content.modifier(Shake(trigger: trigger)).animation(.easeInOut(duration: 0.3), value: trigger)
        }
    }
}

/// A brief dim-and-return on the number when a refresh found nothing new: "checked".
struct SettleFlash: ViewModifier {
    var trigger: Int

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 1.0, trigger: trigger) { view, opacity in
            view.opacity(opacity)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(0.45, duration: 0.01)
                CubicKeyframe(1, duration: 0.3)
            }
        }
    }
}

private struct LockedOverlay: View {
    @Environment(\.openPaywall) private var openPaywall

    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Palette.paper.opacity(0.82))
            .overlay {
                Button {
                    openPaywall(.projects)
                } label: {
                    Label("免费版刷新前两个项目，升级 Pro 刷新全部", systemImage: "lock.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
    }
}
