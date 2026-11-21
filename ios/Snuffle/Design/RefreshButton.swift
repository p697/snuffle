import SnuffleKit
import SwiftUI

/// The big yellow button with the cat behind it. The ring shows progress while refreshing, then slowly charges
/// over ten minutes; when it is full the cat flicks an ear.
struct RefreshButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    var size: CGFloat = 92
    @State private var pressed = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let charge = chargeProgress(at: context.date)
            ZStack(alignment: .top) {
                PeekingCat(state: model.cat, ready: charge >= 1 && !model.isRefreshing, buttonSize: size)
                button(charge: charge)
                CatPaws(out: model.cat.out, buttonSize: size)
            }
            .frame(width: size, height: size)
        }
    }

    private func button(charge: Double) -> some View {
        ZStack {
            Circle().fill(accent)
            Circle()
                .trim(from: 0, to: model.isRefreshing ? model.refreshProgress : charge)
                .stroke(Palette.onAccent.opacity(model.isRefreshing ? 0.85 : 0.35), style: StrokeStyle(lineWidth: model.isRefreshing ? 4 : 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(size * 0.045 + 4)
                .animation(.linear(duration: 0.25), value: model.refreshProgress)
            RefreshArrow()
                .stroke(Palette.onAccent, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.43, height: size * 0.43)
                .rotationEffect(.degrees(model.isRefreshing ? 360 : 0))
                .animation(model.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: model.isRefreshing)
        }
        .overlay(Circle().strokeBorder(Palette.paper, lineWidth: 4))
        .shadow(color: Palette.shadow.opacity(pressed ? 0.2 : 0.22), radius: pressed ? 4 : 11, y: pressed ? 2 : 8)
        .overlay(alignment: .bottom) {
            // The bottom lip that makes the button look pressable.
            Circle().trim(from: 0.12, to: 0.38).stroke(Palette.onAccent.opacity(0.14), lineWidth: 5)
                .rotationEffect(.degrees(pressed ? 180 : 0))
                .padding(6)
                .opacity(pressed ? 0.6 : 1)
        }
        .scaleEffect(pressed ? 0.94 : 1)
        .animation(pressed ? .easeOut(duration: 0.08) : .spring(response: 0.3, dampingFraction: 0.55), value: pressed)
        .contentShape(Circle())
        .onLongPressGesture(minimumDuration: 0, maximumDistance: 40) {
        } onPressingChanged: { isPressing in
            pressed = isPressing
            if isPressing {
                model.pressBegan()
            } else {
                model.pressEnded()
                Task { await model.refreshAll() }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(model.isRefreshing ? "正在刷新" : "刷新全部项目")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("refreshButton")
        .accessibilityAction { Task { await model.refreshAll() } }
    }

    private func chargeProgress(at date: Date) -> Double {
        guard let last = model.lastRefresh else { return 1 }
        return min(1, date.timeIntervalSince(last) / AppModel.chargeDuration)
    }
}

/// The circular refresh arrow from the design (24-point grid).
nonisolated struct RefreshArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        var path = Path()
        path.addArc(center: CGPoint(x: 12 * s, y: 12 * s), radius: 8 * s, startAngle: .degrees(0), endAngle: .degrees(-45), clockwise: false)
        path.move(to: CGPoint(x: 20 * s, y: 4 * s))
        path.addLine(to: CGPoint(x: 20 * s, y: 8 * s))
        path.addLine(to: CGPoint(x: 16 * s, y: 8 * s))
        return path.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}
