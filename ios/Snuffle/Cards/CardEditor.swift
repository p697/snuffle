import SnuffleKit
import SwiftUI

/// "调整卡片": the card itself, where tapping any number picks another from the library and holding one drags it onto
/// another number or an empty place.
struct CardEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let original: Project
    /// The whole project: connecting a missing source from the library changes more than the card.
    @State private var draft: Project
    @State private var editing: CardEditing
    @State private var everywhere = false
    /// Numbers the library read that the cache does not have yet, so the preview shows them at once.
    @State private var measured = MeasuredNumbers()

    init(project: Project) {
        original = project
        _draft = State(initialValue: project)
        _editing = State(initialValue: CardEditing(layout: project.card.visible(in: project)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                hints
                ProjectCard(project: draft, preview: preview, editing: editing)
                    .shadow(color: Palette.shadow.opacity(0.1), radius: 17, y: 12)
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(String(localized: "版式"))
                    ChoiceBar(options: [(1, "一个大数"), (2, "两个大数")], selection: bigCount)
                }
                if draft.posthog != nil {
                    CardGroup {
                        Toggle(isOn: Binding(get: { editing.layout.trend }, set: { on in withAnimation(.snappy) { editing.layout.trend = on } })) {
                            toggleLabel(String(localized: "近 14 天活跃"), String(localized: "大数旁边的小柱子，今天在最右"))
                        }
                        .toggleStyle(InkToggleStyle())
                        .disabled(editing.layout.big.count > 1)
                        RowDivider()
                        Toggle(isOn: Binding(get: { editing.layout.split }, set: { on in withAnimation(.snappy) { editing.layout.split = on } })) {
                            toggleLabel(String(localized: "平台占比"), String(localized: "累计的人里各平台各占多少"))
                        }
                        .toggleStyle(InkToggleStyle())
                    }
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
                    editing.reset(to: CardLayout.standard(for: draft).visible(in: draft))
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink2)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(16)
        }
        .background(Palette.paper.ignoresSafeArea())
        .sheet(item: $editing.picking) { slot in
            CardMetricPicker(project: $draft, measured: $measured, slot: slot, layout: editing.layout) { metric in
                editing.place(metric, at: slot)
            }
        }
        // A tick each time the dragged number comes over a new place it can go.
        .sensoryFeedback(trigger: editing.drag?.over) { _, over in
            model.settings.haptics && over != nil && over != editing.drag?.from ? .selection : nil
        }
        .sensoryFeedback(trigger: editing.drops) { _, _ in
            model.settings.haptics ? .impact(weight: .medium) : nil
        }
    }

    private var preview: ProjectSnapshot {
        var snapshot = model.snapshot(draft.id) ?? ProjectSnapshot(projectId: draft.id, fetchedAt: .now, dayStart: .now)
        snapshot.values = snapshot.values(countedAs: draft.metrics).merging(measured.values(countedAs: draft.metrics)) { $1 }
        snapshot.failures = []
        return snapshot
    }

    /// The two ways to change the card, each with its gesture drawn.
    private var hints: some View {
        VStack(alignment: .leading, spacing: 6) {
            hint("hand.tap", String(localized: "点一个数，换成别的"))
            hint("hand.draw", String(localized: "按住一个数拖到另一个数上，两个换位置；拖到空位就挪过去"))
        }
        .padding(.horizontal, 4)
    }

    private func hint(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink2)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.system(size: 14))
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggleLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink)
            Text(verbatim: detail).font(.system(size: 12)).foregroundStyle(Palette.ink2)
        }
        .padding(.vertical, 8)
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
            editing.layout.big.count
        } set: { count in
            // A second big number: one from the card's rows first, then a common one.
            editing.setBigCount(count, candidates: (editing.layout.small + [.activeToday, .activeWeek, .revenueMonth, .mrr, .reviewsToAnswer, .rating, .newUsers]).filter { $0.isAvailable(in: draft) })
        }
    }

    private func save() {
        var before = original
        before.card = draft.card
        if before != draft { model.save(project: draft) }
        model.saveCard(editing.layout, for: draft, everywhere: everywhere, dragged: editing.drops > 0, countingChanged: before != draft, measured: measured.values(countedAs: draft.metrics))
        dismiss()
    }
}
