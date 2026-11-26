import SnuffleKit
import SwiftUI

/// One slot on a card, for the card editor.
enum CardSlot: Hashable {
    case big(Int)
    case small(Int)
    /// A new small number at the end.
    case add
}

/// What the card editor passes to a card: the layout being edited and what tapping a number does.
struct CardEditing {
    var layout: CardLayout
    var selected: CardSlot?
    var choose: (CardSlot) -> Void
    var remove: (Int) -> Void
}

/// One project on the home screen: a big number with what it is set against and the last 14 days beside it, up to
/// three smaller numbers, and the platform split. Every row has a fixed height and every number stays on screen
/// while refreshing: a line sweeps along the top, then the digits that changed roll up and the rise is marked.
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
        VStack(alignment: .leading, spacing: 12) {
            header
            heroRow
            if !layout.small.isEmpty || editing != nil {
                Rectangle().fill(Palette.line).frame(height: 1)
                stats
            }
            if layout.split {
                SplitBar(platforms: snapshot?.platforms ?? [])
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .top) {
            if stage == .loading {
                SweepLine().clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(failed ? Palette.badLine : .clear, lineWidth: 2)
        }
        .shadow(color: Palette.shadow.opacity(stage == .loading ? (colorScheme == .dark ? 0.6 : 0.16) : 0), radius: 17, y: 14)
        .scaleEffect(stage == .loading ? 1.02 : 1)
        .zIndex(stage == .loading ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: stage)
        .modifier(Shake.Driver(trigger: model.shakes[project.id] ?? 0))
        .overlay {
            if !isPreview, model.isLocked(project) { LockedOverlay() }
        }
        .accessibilityElement(children: editing == nil ? .combine : .contain)
        .accessibilityIdentifier("card-\(project.name)")
    }

    private var failed: Bool { editing == nil && !(snapshot?.failures.isEmpty ?? true) && stage != .loading }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            ProjectBadge(project: project, size: 28)
            Text(project.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            if let zone = project.dayZoneLabel {
                Text(zone)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line))
                    .accessibilityLabel(Text("按 \(zone) 计日"))
            }
            Spacer(minLength: 8)
            stateLabel
        }
        .frame(height: 28)
    }

    @ViewBuilder
    private var stateLabel: some View {
        if stage == .loading {
            Text("正在闻…")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.ink)
        } else if let failure = snapshot?.failures.first, editing == nil {
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

    // MARK: Big numbers

    @ViewBuilder
    private var heroRow: some View {
        if layout.big.count > 1 {
            HStack(alignment: .bottom, spacing: editing == nil ? 12 : 8) {
                ForEach(Array(layout.big.enumerated()), id: \.offset) { index, metric in
                    slot(.big(index)) { hero(metric, base: 44) }
                }
            }
        } else if let metric = layout.big.first {
            HStack(alignment: .bottom, spacing: 12) {
                slot(.big(0)) { hero(metric, base: 54) }
                if layout.trend {
                    VStack(alignment: .trailing, spacing: 4) {
                        DayBars(values: snapshot?.dailyActive ?? [], hot: mark?[.activeToday] != nil)
                            .frame(width: 118, height: 42)
                        Text("近 14 天活跃")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.ink2)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("近 14 天活跃"))
                }
            }
        }
    }

    private func hero(_ metric: Metric, base: CGFloat) -> some View {
        let text = metric.text(snapshot?[metric])
        let rise = mark?[metric]
        return VStack(alignment: .leading, spacing: 4) {
            caption(metric)
                .font(.system(size: 12))
                .frame(height: 16, alignment: .leading)
            HStack(alignment: .center, spacing: 8) {
                Odometer(text: text, size: NumberSize.fit(text, base: base), color: rise != nil && colorScheme == .dark ? accent : Palette.ink)
                    .padding(.horizontal, 2)
                    .background(alignment: .bottomLeading) { Highlighter(on: rise != nil, fading: model.marksFading, height: base * 0.36) }
                    .layoutPriority(1)
                DeltaChip(text: rise.map(metric.delta), visible: rise != nil, size: 14)
            }
            .frame(height: base, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "累计用户 · 今天 +6": the name, then what the number is set against. Long languages drop the reference before
    /// cutting the name.
    private func caption(_ metric: Metric) -> some View {
        let reference = referenceText(metric)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                Text(metric.title(in: project)).foregroundStyle(Palette.ink2)
                if let reference {
                    Text(verbatim: " · ").foregroundStyle(Palette.ink2)
                    Text(reference.text).fontWeight(.semibold).foregroundStyle(reference.tone.color)
                }
            }
            .fixedSize()
            Text(metric.title(in: project)).foregroundStyle(Palette.ink2).lineLimit(1)
        }
    }

    /// The reference, or for numbers without one the detail that makes them readable.
    private func referenceText(_ metric: Metric, compact: Bool = false) -> Metric.ReferenceText? {
        if let reference = metric.reference(in: snapshot, compact: compact) { return reference }
        switch metric {
        case .revenue:
            if let orders = snapshot?.orders { return .init(text: String(localized: "\(orders) 笔", comment: "Number of sales today, after the revenue amount."), tone: .muted) }
            return project.metrics.revenue == .revenueCat ? .init(text: "RevenueCat", tone: .muted) : nil
        default:
            return nil
        }
    }

    // MARK: Small numbers

    private var stats: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(layout.small.enumerated()), id: \.offset) { index, metric in
                slot(.small(index)) { stat(metric) }
            }
            if let editing, layout.small.count < CardLayout.maxSmall {
                AddStatButton(selected: editing.selected == .add) { editing.choose(.add) }
            }
            if editing == nil {
                // Fewer than three keep their width, so numbers line up from card to card.
                ForEach(layout.small.count..<CardLayout.maxSmall, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
            }
        }
    }

    private func stat(_ metric: Metric) -> some View {
        let text = metric.text(snapshot?[metric])
        let rise = mark?[metric]
        let reference = referenceText(metric, compact: true)
        return VStack(alignment: .leading, spacing: 3) {
            // The rise sits beside the name: the number takes the column's whole width.
            HStack(spacing: 4) {
                Text(metric.title(in: project))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                DeltaChip(text: rise.map(metric.delta), visible: rise != nil, size: 10)
                    .fixedSize()
                    .layoutPriority(1)
            }
            .frame(height: 16, alignment: .leading)
            Odometer(text: text, size: NumberSize.fit(text, base: 28), color: rise != nil && colorScheme == .dark ? accent : Palette.ink)
                .padding(.horizontal, 1)
                .background(alignment: .bottomLeading) { Highlighter(on: rise != nil, fading: model.marksFading, height: 10) }
                .frame(height: 30, alignment: .leading)
            Text(reference?.text ?? " ")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(reference?.tone.color ?? Palette.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// In the editor a number is a button with a dashed outline, solid when it is the one being changed.
    @ViewBuilder
    private func slot(_ slot: CardSlot, @ViewBuilder content: () -> some View) -> some View {
        if let editing {
            let selected = editing.selected == slot
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            ZStack(alignment: .topTrailing) {
                Button { editing.choose(slot) } label: { content().contentShape(shape) }
                    .buttonStyle(.plain)
                    .accessibilityHint("换成别的数")
                    .padding(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
                    .background(selected ? accent.opacity(0.3) : .clear, in: shape)
                    .overlay {
                        shape.strokeBorder(selected ? Palette.ink : Palette.faint, style: StrokeStyle(lineWidth: selected ? 2 : 1.5, dash: selected ? [] : [5, 4]))
                    }
                if case .small(let index) = slot {
                    Button { editing.remove(index) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(Palette.paper)
                            .frame(width: 20, height: 20)
                            .background(Palette.ink2, in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("移除")
                    .offset(x: 16, y: -16)
                }
            }
        } else {
            content()
        }
    }
}

/// The line that sweeps along a card's top while its numbers are read.
private struct SweepLine: View {
    @State private var phase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(Palette.ink)
                .frame(width: geometry.size.width * 0.38, height: 3)
                .offset(x: reduceMotion ? geometry.size.width * 0.31 : -geometry.size.width * 0.4 + phase * geometry.size.width * 1.4)
        }
        .frame(height: 3)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: false)) { phase = 1 }
        }
        .accessibilityHidden(true)
    }
}

/// People active on each of the last 14 days; today, the last, in ink, or in the accent when it just went up.
struct DayBars: View {
    var values: [Int]
    var hot = false
    @Environment(\.accent) private var accent

    var body: some View {
        let slots = PostHogQueries.recentDays
        let shown = Array(values.suffix(slots))
        let peak = max(1, shown.max() ?? 1)
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<slots, id: \.self) { index in
                    let offset = index - (slots - shown.count)
                    let value = offset >= 0 ? shown[offset] : 0
                    let isToday = index == slots - 1
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(isToday ? (hot ? accent : Palette.ink) : Palette.faint)
                        .frame(height: max(2, geometry.size.height * CGFloat(value) / CGFloat(peak)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .animation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.7), value: shown)
    }
}

/// Everyone counted, by platform: a bar of shares and, beneath, each platform's count and share.
struct SplitBar: View {
    var platforms: [PlatformCount]
    var height: CGFloat = 8
    var labels = true

    /// Up to four, the rest folded into one.
    private var parts: [PlatformCount] {
        guard platforms.count > 4 else { return platforms }
        let rest = platforms.dropFirst(3).map(\.count).reduce(0, +)
        return Array(platforms.prefix(3)) + [PlatformCount(name: Surface.other.rawValue, count: rest)]
    }

    var body: some View {
        let total = max(1, parts.map(\.count).reduce(0, +))
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let gaps = CGFloat(max(0, parts.count - 1)) * 2
                HStack(spacing: 2) {
                    if parts.isEmpty {
                        Capsule().fill(Palette.line)
                    }
                    ForEach(parts, id: \.name) { part in
                        Capsule()
                            .fill(PlatformStyle.color(part.name))
                            .frame(width: max(3, (geometry.size.width - gaps) * CGFloat(part.count) / CGFloat(total)))
                    }
                }
            }
            .frame(height: height)
            .animation(.easeInOut(duration: 0.6), value: parts)
            if labels {
                ViewThatFits(in: .horizontal) {
                    labelRow(total: total, counts: true)
                    labelRow(total: total, counts: false)
                }
                .frame(height: 16)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.map { "\(PlatformStyle.name($0.name)) \(Format.percent(Double($0.count) / Double(total)))" }.joined(separator: ", "))
    }

    private func labelRow(total: Int, counts: Bool) -> some View {
        HStack(spacing: 12) {
            ForEach(parts, id: \.name) { part in
                HStack(spacing: 5) {
                    Circle().fill(PlatformStyle.color(part.name)).frame(width: 8, height: 8)
                    Text(PlatformStyle.name(part.name)).fontWeight(.semibold).foregroundStyle(Palette.ink)
                    if counts { Text(Format.number(part.count)).foregroundStyle(Palette.ink2) }
                    Text(Format.percent(Double(part.count) / Double(total))).foregroundStyle(Palette.ink2)
                }
                .fixedSize()
            }
            if parts.isEmpty {
                Text("刷新后显示各平台占比").foregroundStyle(Palette.ink2)
            }
        }
        .font(.system(size: 12))
    }
}

/// The highlighter under a number that went up: sweeps in left to right, retracts right to left.
struct Highlighter: View {
    var on: Bool
    var fading: Bool
    var height: CGFloat = 20
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(colorScheme == .dark ? .clear : accent)
            .frame(height: height)
            .scaleEffect(x: on ? 1 : 0, anchor: fading ? .trailing : .leading)
            .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: on ? 0.28 : 0.4), value: on)
            .padding(.bottom, height * 0.15)
    }
}

private struct AddStatButton: View {
    var selected: Bool
    var action: () -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        Button(action: action) {
            Label("加一个数", systemImage: "plus")
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(selected ? accent.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.ink, style: StrokeStyle(lineWidth: 1.5, dash: selected ? [] : [5, 4])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("加一个数")
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
