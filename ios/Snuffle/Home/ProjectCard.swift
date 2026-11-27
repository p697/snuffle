import SnuffleKit
import SwiftUI

/// One project on the home screen: a big number with what it is set against and the last 14 days beside it, up to
/// two rows of smaller numbers, and the platform split. Every row has a fixed height and every number stays on screen
/// while refreshing: a short stroke runs round the card's outline, then the digits that changed roll up and the rise
/// is marked.
struct ProjectCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var colorScheme
    var project: Project
    /// Numbers for a project that is not saved yet (the connect flow's "连上了" page); nil on the home screen.
    var preview: ProjectSnapshot?
    var previewLoading = false
    /// Set by the card editor: every number becomes a button that picks another and can be dragged onto another.
    var editing: CardEditing?

    private var isPreview: Bool { preview != nil || previewLoading || editing != nil }
    private var snapshot: ProjectSnapshot? { preview ?? model.snapshot(project.id) }
    private var stage: CardStage { previewLoading ? .loading : editing != nil ? .rest : model.stage(project.id) }
    /// The editor's layout is already the project's visible one; its slots must stay as they are while dragging.
    private var layout: CardLayout { editing?.shown ?? project.card.visible(in: project) }
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
        .overlay {
            if stage == .loading { OutlineTrace(cornerRadius: 24) }
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
        .modifier(CardDropArea(editing: editing))
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
            Text("闻一闻…")
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
                    slot(.big(index), metric: metric) { hero(metric, base: 44) }
                }
            }
        } else if let metric = layout.big.first {
            HStack(alignment: .bottom, spacing: 12) {
                slot(.big(0), metric: metric) { hero(metric, base: 54) }
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
        VStack(alignment: .leading, spacing: editing == nil ? 14 : 10) {
            ForEach(Array(layout.rows.enumerated()), id: \.offset) { row, metrics in
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(metrics.enumerated()), id: \.offset) { index, metric in
                        slot(.small(row: row, index: index), metric: metric) { stat(metric) }
                    }
                    if let editing, metrics.count < CardLayout.perRow {
                        Opening(slot: .add(row: row), editing: editing, wide: false)
                    }
                    // Fewer than three keep their width, so numbers line up from row to row and card to card.
                    let open = CardLayout.perRow - metrics.count - (editing == nil ? 0 : 1)
                    ForEach(0..<max(0, open), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
            if let editing, layout.rows.count < CardLayout.maxRows {
                Opening(slot: .add(row: layout.rows.count), editing: editing, wide: true)
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

    /// In the editor a number is a button with a dashed outline: tap it for the library, or hold and drag it onto
    /// another number or an empty place. The number under a dragged one already shows them traded.
    @ViewBuilder
    private func slot(_ slot: CardSlot, metric: Metric, @ViewBuilder content: () -> some View) -> some View {
        if let editing {
            let look = editing.look(slot)
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            ZStack(alignment: .topTrailing) {
                // A tap rather than a Button: a Button's press keeps the hold from lifting the number into a drag.
                content()
                    .id(metric)
                    .transition(.asymmetric(insertion: .scale(scale: 0.88).combined(with: .opacity), removal: .opacity))
                    .padding(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
                    .contentShape(shape)
                    .onTapGesture { editing.pick(slot) }
                    .background(look.fill(accent), in: shape)
                    .overlay { shape.strokeBorder(look.stroke, style: look.strokeStyle) }
                    .opacity(look == .lifted ? 0.4 : 1)
                    .scaleEffect(look == .landing ? 1.03 : 1)
                    .contentShape(.dragPreview, shape)
                    .onDrag {
                        editing.lift(slot)
                        return NSItemProvider(object: metric.id as NSString)
                    } preview: {
                        DragTile(title: metric.title(in: project), value: metric.text(snapshot?[metric]), big: slot.isBig)
                    }
                    .onDrop(of: cardDragTypes, delegate: SlotDrop(slot: slot, editing: editing))
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { editing.pick(slot) }
                    .accessibilityIdentifier(slot.identifier)
                    .accessibilityHint("换成别的数；按住拖到别的数上，两个数换位置")
                    .accessibilityAction(named: "和前一个数换位置") { editing.shift(slot, by: -1) }
                    .accessibilityAction(named: "和后一个数换位置") { editing.shift(slot, by: 1) }
                if !slot.isBig {
                    Button { editing.remove(slot) } label: {
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
                    // Faded rather than removed while dragging, so the slots under the finger stay as they are.
                    .opacity(editing.dragging ? 0 : 1)
                    .allowsHitTesting(!editing.dragging)
                }
            }
        } else {
            content()
        }
    }
}

extension CardSlot {
    fileprivate var isBig: Bool {
        if case .big = self { true } else { false }
    }

    /// For UI tests: "slot-big-0", "slot-1-2".
    fileprivate var identifier: String {
        switch self {
        case .big(let index): "slot-big-\(index)"
        case .small(let row, let index): "slot-\(row)-\(index)"
        case .add(let row): "slot-add-\(row)"
        }
    }
}

extension CardEditing.Look {
    fileprivate func fill(_ accent: Color) -> Color {
        switch self {
        case .plain, .lifted: .clear
        case .selected: accent.opacity(0.3)
        case .trading: accent.opacity(0.15)
        case .landing: accent.opacity(0.4)
        }
    }

    fileprivate var stroke: Color {
        self == .plain ? Palette.faint : Palette.ink
    }

    fileprivate var strokeStyle: StrokeStyle {
        let solid = self == .selected || self == .landing
        return StrokeStyle(lineWidth: solid ? 2 : 1.5, dash: solid ? [] : [5, 4])
    }
}

/// The card being edited takes a drag anywhere between its numbers, so the drag stays on the card; letting go
/// there changes nothing.
private struct CardDropArea: ViewModifier {
    var editing: CardEditing?

    func body(content: Content) -> some View {
        if let editing {
            content.onDrop(of: cardDragTypes, delegate: CardDrop(editing: editing))
        } else {
            content
        }
    }
}

/// An empty place on the card being edited: the end of a row with room, or a new row. Tap it to add a number from
/// the library, or drop a dragged number there.
private struct Opening: View {
    var slot: CardSlot
    var editing: CardEditing
    /// A whole row: the next one, or the first when there is none.
    var wide: Bool
    @Environment(\.accent) private var accent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let look = editing.look(slot)
        let hot = look == .landing || look == .selected
        let takes = editing.dragging && editing.accepts(slot)
        Button { editing.pick(slot) } label: {
            Label(title(takes: takes), systemImage: takes ? "arrow.down.to.line" : "plus")
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: wide ? 44 : 60)
                .background(hot ? accent.opacity(0.4) : .clear, in: shape)
                .overlay {
                    shape.strokeBorder(Palette.ink.opacity(editing.dragging && !takes ? 0.25 : 1), style: StrokeStyle(lineWidth: hot ? 2 : 1.5, dash: hot ? [] : [5, 4]))
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .scaleEffect(look == .landing ? 1.03 : 1)
        .onDrop(of: cardDragTypes, delegate: SlotDrop(slot: slot, editing: editing))
        .accessibilityLabel(Text(title(takes: takes)))
        .accessibilityIdentifier(wide ? "addRow" : "addNumber")
    }

    private func title(takes: Bool) -> LocalizedStringKey {
        if takes { return "放到这里" }
        return wide && slot != .add(row: 0) ? "再加一行数" : "加一个数"
    }
}

/// What follows the finger while a number is dragged.
private struct DragTile: View {
    var title: String
    var value: String
    var big: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
            Text(verbatim: value)
                .font(Typeface.number(big ? 40 : 28))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 96, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.ink, lineWidth: 2))
    }
}

/// A short ink stroke running round a card's outline while its numbers are read. It follows the card's own rounded
/// shape, so it turns with the corners instead of running past them. With Reduce Motion the whole outline is drawn, still.
private struct OutlineTrace: View {
    var cornerRadius: CGFloat
    @State private var phase: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TraceSegment(phase: phase, length: reduceMotion ? 1 : 0.16, cornerRadius: cornerRadius, inset: 1.25)
            .stroke(Palette.ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The part of a rounded rectangle's outline from `phase` to `phase + length`, wrapping past the start.
nonisolated private struct TraceSegment: Shape {
    var phase: Double
    var length: Double
    var cornerRadius: CGFloat
    /// Half the stroke width, so the stroke stays inside the card.
    var inset: CGFloat

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let outline = RoundedRectangle(cornerRadius: cornerRadius - inset, style: .continuous)
            .path(in: rect.insetBy(dx: inset, dy: inset))
        guard length < 1 else { return outline }
        let start = phase - phase.rounded(.down)
        let end = start + length
        var path = outline.trimmedPath(from: start, to: min(end, 1))
        if end > 1 { path.addPath(outline.trimmedPath(from: 0, to: end - 1)) }
        return path
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
