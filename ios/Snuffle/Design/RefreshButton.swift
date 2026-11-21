import SnuffleKit
import SwiftUI

/// The big yellow button with the cat behind it: a flat circle and the arrow. A progress ring shows only while
/// refreshing. Ten minutes after the last refresh the cat starts flicking an ear: worth another sniff.
struct RefreshButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    var size: CGFloat = 92
    @State private var pressed = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ZStack(alignment: .top) {
                PeekingCat(state: model.cat, ready: isCharged(at: context.date) && !model.isRefreshing, buttonSize: size)
                button
                CatPaws(out: model.cat.out, buttonSize: size)
            }
            .frame(width: size, height: size)
        }
    }

    private var button: some View {
        ZStack {
            Circle().fill(accent)
            if model.isRefreshing {
                Circle()
                    .trim(from: 0, to: model.refreshProgress)
                    .stroke(Palette.onAccent.opacity(0.85), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(size * 0.045 + 4)
                    .animation(.linear(duration: 0.25), value: model.refreshProgress)
                    .transition(.opacity)
            }
            RefreshArrow()
                .stroke(Palette.onAccent, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.43, height: size * 0.43)
                .rotationEffect(.degrees(model.isRefreshing ? 360 : 0))
                .animation(model.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: model.isRefreshing)
        }
        .animation(.easeOut(duration: 0.2), value: model.isRefreshing)
        .shadow(color: Palette.shadow.opacity(pressed ? 0.14 : 0.18), radius: pressed ? 4 : 10, y: pressed ? 2 : 6)
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

    private func isCharged(at date: Date) -> Bool {
        guard let last = model.lastRefresh else { return true }
        return date.timeIntervalSince(last) >= AppModel.chargeDuration
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
