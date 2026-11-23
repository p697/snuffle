import SnuffleKit
import SwiftUI

/// "调整卡片": the card itself, where tapping any number picks another from the library.
struct CardEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let original: Project
    /// The whole project: connecting a missing source from the library changes more than the card.
    @State private var draft: Project
    @State private var layout: CardLayout
    @State private var everywhere = false
    @State private var picking: CardSlot?
    /// Numbers the library read that the cache does not have yet, so the preview shows them at once.
    @State private var measured: [Metric: Double] = [:]

    init(project: Project) {
        original = project
        _draft = State(initialValue: project)
        _layout = State(initialValue: project.card.visible(in: project))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Text("点卡片上的任何一个数，换成你想看的。")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.ink2)
                    .padding(.horizontal, 4)
                ProjectCard(project: draft, preview: preview, editing: CardEditing(layout: layout, selected: picking, choose: { picking = $0 }, remove: remove))
                    .shadow(color: Palette.shadow.opacity(0.1), radius: 17, y: 12)
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(String(localized: "版式"))
                    ChoiceBar(options: [(1, "一个大数"), (2, "两个大数")], selection: bigCount)
                }
                if model.workspace.projects.count > 1 {
                    CardGroup {
                        Toggle("其他项目也这样显示", isOn: $everywhere)
                            .toggleStyle(InkToggleStyle())
                            .padding(.vertical, 6)
                        RowDivider()
                        Text("所有项目用同一套数；哪个项目没连对应的数据源，就跳过那个数。按事件算的数只留在这个项目。")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 12)
                    }
                }
                Button("恢复默认") {
                    withAnimation(.snappy) { layout = CardLayout.standard(for: draft).visible(in: draft) }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink2)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(16)
        }
        .background(Palette.paper.ignoresSafeArea())
        .sheet(item: $picking) { slot in
            CardMetricPicker(project: $draft, measured: $measured, slot: slot, layout: layout) { metric in
                withAnimation(.snappy) { apply(metric, to: slot) }
            }
        }
    }

    private var preview: ProjectSnapshot {
        var snapshot = model.snapshot(draft.id) ?? ProjectSnapshot(projectId: draft.id, fetchedAt: .now, dayStart: .now)
        snapshot.values.merge(measured) { $1 }
        snapshot.failures = []
        return snapshot
    }

    private var header: some View {
        HStack {
            RoundIconButton(systemName: "xmark", label: String(localized: "取消")) { dismiss() }
            Spacer()
            Text("\(draft.name) 的卡片")
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer()
            Button("完成", action: save)
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(Palette.paper)
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .background(Palette.ink, in: Capsule())
                .accessibilityIdentifier("saveCard")
        }
    }

    private var bigCount: Binding<Int> {
        Binding {
            layout.big.count
        } set: { count in
            withAnimation(.snappy) {
                if count < layout.big.count {
                    layout = CardLayout(big: Array(layout.big.prefix(count)), small: layout.small)
                } else if let second = secondBig {
                    layout = CardLayout(big: layout.big + [second], small: layout.small.filter { $0 != second })
                }
            }
        }
    }

    /// The number a second big slot starts with: the first that is not big already, preferring one the card had.
    private var secondBig: Metric? {
        let preferred: [Metric] = layout.small + [.activeToday, .revenue, .mrr, .reviewsToAnswer, .online, .newUsers]
        return preferred.first { $0.isAvailable(in: draft) && !layout.big.contains($0) }
    }

    private func remove(_ index: Int) {
        withAnimation(.snappy) {
            var small = layout.small
            small.remove(at: index)
            layout = CardLayout(big: layout.big, small: small)
        }
    }

    /// Puts `metric` in `slot`. A number already elsewhere on the card swaps places, so nothing shows twice.
    private func apply(_ metric: Metric, to slot: CardSlot) {
        var big = layout.big
        var small = layout.small
        switch slot {
        case .big(let index):
            if let other = big.firstIndex(of: metric) {
                big.swapAt(index, other)
            } else {
                small.removeAll { $0 == metric }
                big[index] = metric
            }
        case .small(let index):
            if let other = small.firstIndex(of: metric) {
                small.swapAt(index, other)
            } else {
                small[index] = metric
            }
        case .add:
            small.append(metric)
        }
        layout = CardLayout(big: big, small: small)
    }

    private func save() {
        var before = original
        before.card = draft.card
        if before != draft { model.save(project: draft) }
        model.saveCard(layout, for: draft, everywhere: everywhere, countingChanged: before != draft, measured: measured)
        dismiss()
    }
}

extension CardSlot: Identifiable {
    var id: Self { self }
}
