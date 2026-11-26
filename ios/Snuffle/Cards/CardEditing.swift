import SnuffleKit
import SwiftUI
import UniformTypeIdentifiers

/// The card being edited: its layout, the number being changed and the number being dragged. While a dragged number
/// is held over another, the card shows the two already traded; letting go there keeps it, anywhere else puts
/// everything back.
@MainActor @Observable
final class CardEditing {
    var layout: CardLayout
    /// The slot whose library is open.
    var picking: CardSlot?
    private(set) var drag: Drag?
    /// Numbers moved by dragging, for the drop's haptic and the saved event.
    private(set) var drops = 0

    struct Drag: Equatable {
        var from: CardSlot
        /// The slot under the finger that takes the number; nil between slots or over one that cannot.
        var over: CardSlot?
        /// Whether the finger is over the card. False until the drag first moves, and again once it leaves or ends
        /// anywhere but a slot, so nothing stays lifted.
        var onCard: Bool
    }

    /// How a slot looks right now.
    enum Look {
        case plain, selected
        /// The dragged number where it came from.
        case lifted
        /// Where the dragged number came from, showing the number it would trade with.
        case trading
        /// Where the dragged number would land.
        case landing
    }

    init(layout: CardLayout) {
        self.layout = layout
    }

    /// While a number is dragged over the card.
    var dragging: Bool { drag?.onCard == true }

    /// The card as drawn: with the dragged number already traded with the one under the finger.
    var shown: CardLayout {
        guard let drag, drag.onCard, let over = drag.over, layout[over] != nil else { return layout }
        return layout.moving(from: drag.from, to: over) ?? layout
    }

    func look(_ slot: CardSlot) -> Look {
        if picking == slot { return .selected }
        guard let drag, drag.onCard else { return .plain }
        if slot == drag.from {
            guard let over = drag.over, over != slot else { return .lifted }
            return layout[over] != nil ? .trading : .lifted
        }
        return slot == drag.over ? .landing : .plain
    }

    // MARK: Tapping

    func pick(_ slot: CardSlot) {
        drag = nil
        picking = slot
    }

    func place(_ metric: Metric, at slot: CardSlot) {
        withAnimation(.snappy) { layout = layout.placing(metric, at: slot) }
    }

    func remove(_ slot: CardSlot) {
        withAnimation(.snappy) { layout = layout.removing(slot) }
    }

    func reset(to layout: CardLayout) {
        drag = nil
        withAnimation(.snappy) { self.layout = layout }
    }

    /// One or two big numbers. A second one comes from `candidates`, taken out of its row; going back to one puts
    /// it where there is room beneath.
    func setBigCount(_ count: Int, candidates: [Metric]) {
        withAnimation(.snappy) {
            if count < layout.big.count {
                layout = layout.openings.lazy.compactMap { self.layout.moving(from: .big(1), to: $0) }.first ?? layout.removing(.big(1))
            } else if count > layout.big.count, let metric = candidates.first(where: { !layout.big.contains($0) }) {
                layout = CardLayout(big: layout.big + [metric], rows: layout.rows.map { $0.filter { $0 != metric } }, trend: layout.trend, split: layout.split)
            }
        }
    }

    /// VoiceOver's way to move a number: trade places with the one before or after it in reading order.
    func shift(_ slot: CardSlot, by offset: Int) {
        let slots = layout.slots
        guard let index = slots.firstIndex(of: slot), slots.indices.contains(index + offset),
              let moved = layout.moving(from: slot, to: slots[index + offset]) else { return }
        withAnimation(.snappy) { layout = moved }
    }

    // MARK: Dragging

    func lift(_ slot: CardSlot) {
        picking = nil
        // Nothing changes on the card until the finger moves over it: the system also asks for the dragged item
        // when no drag follows (right after a drop, or a hold let go in place), and those must leave nothing lifted.
        drag = Drag(from: slot, over: nil, onCard: false)
    }

    func accepts(_ slot: CardSlot) -> Bool {
        guard let drag else { return false }
        return layout.moving(from: drag.from, to: slot) != nil
    }

    /// The finger came over `slot`, or over the card between slots when nil.
    func enter(_ slot: CardSlot?) {
        guard drag != nil else { return }
        let over = slot.flatMap { accepts($0) ? $0 : nil }
        withAnimation(.snappy(duration: 0.22)) {
            drag?.over = over
            drag?.onCard = true
        }
    }

    /// The finger left `slot`, or the card when nil. Another slot it already entered keeps the drag.
    func exit(_ slot: CardSlot?) {
        guard let drag, drag.over == slot.flatMap({ accepts($0) ? $0 : nil }) else { return }
        withAnimation(.snappy(duration: 0.22)) {
            self.drag?.over = nil
            self.drag?.onCard = false
        }
    }

    func drop(on slot: CardSlot) -> Bool {
        guard let drag, let moved = layout.moving(from: drag.from, to: slot) else {
            cancel()
            return false
        }
        withAnimation(.snappy) {
            layout = moved
            self.drag = nil
        }
        if drag.from != slot { drops += 1 }
        return true
    }

    func cancel() {
        withAnimation(.snappy) { drag = nil }
    }
}

/// A slot of the card being edited, as a place to drop a dragged number.
struct SlotDrop: DropDelegate {
    let slot: CardSlot
    let editing: CardEditing

    func validateDrop(info: DropInfo) -> Bool { editing.drag != nil }
    func dropEntered(info: DropInfo) { editing.enter(slot) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: editing.accepts(slot) ? .move : .forbidden) }
    func dropExited(info: DropInfo) { editing.exit(slot) }
    func performDrop(info: DropInfo) -> Bool { editing.drop(on: slot) }
}

/// The card between its slots: keeps the drag going, and letting go there changes nothing.
struct CardDrop: DropDelegate {
    let editing: CardEditing

    func validateDrop(info: DropInfo) -> Bool { editing.drag != nil }
    func dropEntered(info: DropInfo) { editing.enter(nil) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .cancel) }
    func dropExited(info: DropInfo) { editing.exit(nil) }
    func performDrop(info: DropInfo) -> Bool {
        editing.cancel()
        return false
    }
}

extension CardSlot: @retroactive Identifiable {
    public var id: Self { self }
}

/// What a dragged number carries. Only the card reads it, from the editor's own state.
let cardDragTypes: [UTType] = [.plainText]
