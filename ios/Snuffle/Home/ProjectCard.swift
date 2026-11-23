import SnuffleKit
import SwiftUI

/// One slot on a card, for the card editor.
enum CardSlot: Hashable {
    case big(Int)
    case small(Int)
    /// A new pill at the end.
    case add
}

/// What the card editor passes to a card: the layout being edited and what tapping a number does.
struct CardEditing {
    var layout: CardLayout
    var selected: CardSlot?
    var choose: (CardSlot) -> Void
    var remove: (Int) -> Void
}

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
    /// Set by the card editor: every number becomes a button that picks another.
    var editing: CardEditing?

    private var isPreview: Bool { preview != nil || previewLoading || editing != nil }
    private var snapshot: ProjectSnapshot? { preview ?? model.snapshot(project.id) }
    private var stage: CardStage { previewLoading ? .loading : editing != nil ? .rest : model.stage(project.id) }
    private var layout: CardLayout { (editing?.layout ?? project.card).visible(in: project) }
    private var mark: SnapshotChange? { editing == nil && !model.marksFading ? model.marks[project.id] : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            bigRow
            if !layout.small.isEmpty || editing != nil {
                pills
            }
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
        .accessibilityElement(children: editing == nil ? .combine : .contain)
        .accessibilityIdentifier("card-\(project.name)")
    }

    private var failed: Bool { editing == nil && !(snapshot?.failures.isEmpty ?? true) && stage != .loading }

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
        if let failure = snapshot?.failures.first, stage != .loading, editing == nil {
            Button {
                Task { await model.refresh([project], trigger: .project) }
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

    @ViewBuilder
    private var bigRow: some View {
        if layout.big.count > 1 {
            HStack(alignment: .bottom, spacing: editing == nil ? 12 : 8) {
                ForEach(Array(layout.big.enumerated()), id: \.offset) { index, metric in
                    slot(.big(index)) { big(metric, base: 46, chip: false) }
                }
            }
        } else if let metric = layout.big.first {
            HStack(alignment: .bottom, spacing: 12) {
                slot(.big(0)) { big(metric, base: 56, chip: true) }
                if metric == .newUsers, editing == nil {
                    HourBars(values: snapshot?.hourlyNewUsers ?? [])
                        .frame(width: 104, height: 44)
                }
            }
        }
    }

    private func big(_ metric: Metric, base: CGFloat, chip: Bool) -> some View {
        let text = metric.text(snapshot?[metric])
        let rise = mark?[metric]
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Odometer(
                    text: text,
                    size: NumberSize.fit(text, base: base),
                    spinning: stage == .loading,
                    color: rise != nil && colorScheme == .dark ? accent : Palette.ink
                )
                .padding(.horizontal, 2)
                .background(alignment: .bottomLeading) { Highlighter(on: rise != nil, fading: model.marksFading) }
                .modifier(SettleFlash(trigger: model.settles[project.id] ?? 0))
                .layoutPriority(1)
                if chip {
                    DeltaChip(text: rise.map(metric.delta), visible: rise != nil, size: 14)
                }
            }
            .frame(height: 54, alignment: .bottomLeading)
            caption(metric, single: chip)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink2)
                .frame(height: 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The line under a big number. Alone, long languages drop the label before the comparison rather than cutting
    /// it off; side by side, the label stays, since two numbers need their names.
    private func caption(_ metric: Metric, single: Bool) -> some View {
        let label = captionLabel(metric, short: !single)
        let detail = captionDetail(metric)
        return ViewThatFits(in: .horizontal) {
            Text(([label] + [detail].compactMap { $0 }).joined(separator: " · ")).fixedSize()
            if single, let detail { Text(detail).fixedSize() }
            Text(label).lineLimit(1)
        }
    }

    private func captionLabel(_ metric: Metric, short: Bool) -> String {
        switch metric {
        case .newUsers: short ? metric.title : String(localized: "今日新增用户")
        case .revenue: String(localized: "今日收入")
        default: metric.title
        }
    }

    private func captionDetail(_ metric: Metric) -> String? {
        switch metric {
        case .newUsers:
            return snapshot?.newUsersYesterday.map { String(localized: "昨天此时 \(Format.number($0))") }
        case .revenue:
            if let orders = snapshot?.orders { return String(localized: "\(orders) 笔", comment: "Number of sales today, after the revenue amount.") }
            return project.metrics.revenue == .revenueCat ? "RevenueCat" : nil
        case .reviewsToAnswer:
            return [project.appStore != nil ? "App Store" : nil, project.googlePlay != nil ? "Google Play" : nil].compactMap { $0 }.joined(separator: " + ")
        default:
            return nil
        }
    }

    /// Whole pills only: when they do not fit (long languages), the last ones go first.
    @ViewBuilder
    private var pills: some View {
        if editing != nil {
            // Editing wraps instead, so every pill and the add button stay reachable.
            FlowLayout(spacing: 6) {
                ForEach(Array(layout.small.enumerated()), id: \.offset) { index, metric in
                    slot(.small(index)) { pill(metric) }
                }
                if layout.small.count < CardLayout.maxSmall { AddPillButton(selected: editing?.selected == .add) { editing?.choose(.add) } }
            }
        } else {
            ViewThatFits(in: .horizontal) {
                ForEach((1...max(1, layout.small.count)).reversed(), id: \.self) { count in
                    HStack(spacing: 6) {
                        ForEach(Array(layout.small.prefix(count).enumerated()), id: \.offset) { _, metric in pill(metric) }
                    }
                    .fixedSize()
                }
            }
            .frame(height: 28, alignment: .leading)
            .clipped()
        }
    }

    private func pill(_ metric: Metric) -> some View {
        var value = metric.text(snapshot?[metric])
        if metric == .revenue, let orders = snapshot?.orders, snapshot?.revenue != nil {
            value += " · " + String(localized: "\(orders) 笔", comment: "Number of sales today, after the revenue amount.")
        }
        return Pill(label: metric.title, value: value, hot: mark?[metric] != nil)
    }

    /// In the editor a number is a button with a dashed outline, solid when it is the one being changed.
    @ViewBuilder
    private func slot(_ slot: CardSlot, @ViewBuilder content: () -> some View) -> some View {
        if let editing {
            let selected = editing.selected == slot
            let shape = RoundedRectangle(cornerRadius: slot.isBig ? 16 : 99, style: .continuous)
            HStack(spacing: 6) {
                Button { editing.choose(slot) } label: { content().contentShape(shape) }
                    .buttonStyle(.plain)
                    .accessibilityHint("换成别的数")
                if case .small(let index) = slot {
                    Button { editing.remove(index) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(Palette.ink2)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("移除")
                    .padding(.leading, -8)
                }
            }
            .padding(slot.isBig ? EdgeInsets(top: 4, leading: 8, bottom: 6, trailing: 8) : EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 4))
            .background(selected ? accent.opacity(0.3) : .clear, in: shape)
            .overlay {
                shape.strokeBorder(selected ? Palette.ink : Palette.faint, style: StrokeStyle(lineWidth: selected ? 2 : 1.5, dash: selected ? [] : [5, 4]))
            }
        } else {
            content()
        }
    }
}

extension CardSlot {
    var isBig: Bool { if case .big = self { true } else { false } }
}

/// The highlighter under a number that went up: sweeps in left to right, retracts right to left.
struct Highlighter: View {
    var on: Bool
    var fading: Bool
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(colorScheme == .dark ? .clear : accent)
            .frame(height: 20)
            .scaleEffect(x: on ? 1 : 0, anchor: fading ? .trailing : .leading)
            .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: on ? 0.28 : 0.4), value: on)
            .padding(.bottom, 3)
    }
}

private struct AddPillButton: View {
    var selected: Bool
    var action: () -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        Button(action: action) {
            Label("小数", systemImage: "plus")
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(selected ? accent.opacity(0.3) : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.ink, style: StrokeStyle(lineWidth: 1.5, dash: selected ? [] : [5, 4])))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("加一个小数")
    }
}

struct Pill: View {
    var label: String?
    var value: String
    var hot = false
    @Environment(\.accent) private var accent

    init(label: String? = nil, value: String, hot: Bool = false) {
        self.label = label
        self.value = value
        self.hot = hot
    }

    init(text: String) {
        self.init(value: text)
    }

    var body: some View {
        HStack(spacing: 4) {
            if let label {
                Text(label).fontWeight(.medium).foregroundStyle(hot ? Palette.onAccent.opacity(0.7) : Palette.ink2)
            }
            Text(value).foregroundStyle(hot ? Palette.onAccent : Palette.ink)
        }
        .font(.system(size: 12.5, weight: .semibold))
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
