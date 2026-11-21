import SwiftUI

/// The cat that lives behind the refresh button, drawn on the same 120 × 84 grid as the design.
/// At rest only its ear tips clear the button; `out` brings its head up and its paws onto the rim.
struct PeekingCat: View {
    var state: CatState
    /// Set ten minutes after the last refresh: the right ear flicks now and then.
    var ready: Bool
    var buttonSize: CGFloat

    private var width: CGFloat { buttonSize * 0.78 }
    private var height: CGFloat { width * 0.7 }

    var body: some View {
        ZStack(alignment: .top) {
            CatHead(state: state, ready: ready)
                .frame(width: width, height: height)
                .offset(y: -buttonSize * 0.07 + headLift)
                .animation(.spring(response: 0.38, dampingFraction: state.ducking ? 1 : 0.62), value: state.out)
                .animation(.easeOut(duration: 0.1), value: state.ducking)
        }
        .frame(width: buttonSize, height: buttonSize, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var headLift: CGFloat {
        if state.ducking { return height * 0.16 }
        return state.out ? -height * 0.6 : 0
    }
}

/// Paws drawn over the button rim while the head is up.
struct CatPaws: View {
    var out: Bool
    var buttonSize: CGFloat

    var body: some View {
        let paw = buttonSize * 0.15
        HStack(spacing: buttonSize * 0.32) {
            Paw(size: paw).rotationEffect(.degrees(-14), anchor: .bottom)
            Paw(size: paw).rotationEffect(.degrees(14), anchor: .bottom)
        }
        .scaleEffect(out ? 1 : 0, anchor: .bottom)
        .animation(.spring(response: 0.25, dampingFraction: 0.55).delay(out ? 0.12 : 0), value: out)
        .frame(width: buttonSize, height: buttonSize, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct Paw: View {
        var size: CGFloat

        var body: some View {
            UnevenRoundedRectangle(topLeadingRadius: size / 2, bottomLeadingRadius: size * 0.42, bottomTrailingRadius: size * 0.42, topTrailingRadius: size / 2)
                .fill(Palette.cat)
                .overlay(alignment: .top) {
                    // Two toe lines.
                    HStack(spacing: size * 0.24) {
                        Capsule().frame(width: 1.4, height: size * 0.28)
                        Capsule().frame(width: 1.4, height: size * 0.28)
                    }
                    .foregroundStyle(Palette.paper.opacity(0.5))
                    .padding(.top, 1)
                }
                .frame(width: size, height: size * 0.67)
                .background(UnevenRoundedRectangle(topLeadingRadius: size / 2, bottomLeadingRadius: size * 0.42, bottomTrailingRadius: size * 0.42, topTrailingRadius: size / 2).stroke(Palette.paper, lineWidth: 4))
        }
    }
}

private struct CatHead: View {
    var state: CatState
    var ready: Bool
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sniffStart = Date()

    var body: some View {
        TimelineView(.animation(paused: !(state.sniffing || ready) || reduceMotion)) { context in
            let sniff = sniffPhase(at: context.date)
            Canvas { canvas, size in
                let scale = size.width / 120
                canvas.scaleBy(x: scale, y: scale)
                canvas.translateBy(x: 0, y: sniff.bob)
                draw(&canvas, sniff: sniff, twitch: twitchAngle(at: context.date))
            }
        }
        .keyframeAnimator(initialValue: 0.0, trigger: hopTrigger) { content, lift in
            content.offset(y: lift)
        } keyframes: { _ in
            // A sale gets a second hop; otherwise the second hop has zero height.
            KeyframeTrack {
                CubicKeyframe(-hopHeight, duration: 0.2)
                SpringKeyframe(0, duration: 0.3, spring: .bouncy)
                CubicKeyframe(state.reaction == .cheer ? -hopHeight : 0, duration: 0.2)
                SpringKeyframe(0, duration: 0.3, spring: .bouncy)
            }
        }
        .onChange(of: state.sniffing) { _, sniffing in if sniffing { sniffStart = .now } }
    }

    private var hopHeight: CGFloat { 9 }

    /// Hops on glee and cheer; the token makes repeated reactions hop again.
    private var hopTrigger: Int {
        (state.reaction == .glee || state.reaction == .cheer) ? state.reactionToken : -1
    }

    struct Sniff {
        var bob: CGFloat = 0
        var nose: CGFloat = 1
        var puff: Double = 0
    }

    /// Two quick sniffs every 1.2 s, as in the prototype's keyframes (8% and 24% peaks).
    private func sniffPhase(at date: Date) -> Sniff {
        guard state.sniffing, !reduceMotion else { return Sniff() }
        let t = date.timeIntervalSince(sniffStart).truncatingRemainder(dividingBy: 1.2) / 1.2
        func pulse(_ center: Double) -> Double { max(0, 1 - abs(t - center) / 0.08) }
        let p = max(pulse(0.08), pulse(0.24))
        return Sniff(bob: -3 * p, nose: 1 + 0.45 * p, puff: max(pulse(0.09), pulse(0.25)) * 1.2)
    }

    /// The right ear flicks twice at the start of every 3.2 s while `ready`.
    private func twitchAngle(at date: Date) -> Double {
        guard ready, !state.out, !reduceMotion else { return 0 }
        let t = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 3.2) / 3.2
        switch t {
        case 0..<0.02: return 16 * t / 0.02
        case 0.02..<0.04: return 16 * (1 - (t - 0.02) / 0.02)
        case 0.04..<0.055: return 10 * (t - 0.04) / 0.015
        case 0.055..<0.07: return 10 * (1 - (t - 0.055) / 0.015)
        default: return 0
        }
    }

    private func draw(_ canvas: inout GraphicsContext, sniff: Sniff, twitch: Double) {
        let cat = GraphicsContext.Shading.color(Palette.cat)
        let eye = GraphicsContext.Shading.color(accent)
        let flat = state.reaction == .flat

        // Scent lines either side of the head while sniffing.
        if sniff.puff > 0 {
            var puffs = Path()
            puffs.move(to: CGPoint(x: 13, y: 31)); puffs.addQuadCurve(to: CGPoint(x: 13, y: 41), control: CGPoint(x: 9, y: 36))
            puffs.move(to: CGPoint(x: 6, y: 27)); puffs.addQuadCurve(to: CGPoint(x: 6, y: 45), control: CGPoint(x: 0, y: 36))
            puffs.move(to: CGPoint(x: 107, y: 31)); puffs.addQuadCurve(to: CGPoint(x: 107, y: 41), control: CGPoint(x: 111, y: 36))
            puffs.move(to: CGPoint(x: 114, y: 27)); puffs.addQuadCurve(to: CGPoint(x: 114, y: 45), control: CGPoint(x: 120, y: 36))
            canvas.stroke(puffs, with: .color(Palette.cat.opacity(min(1, sniff.puff))), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }

        // Ears rotate about their bases: flattened outward on a failure, the right one flicks when ready.
        canvas.drawLayer { layer in
            layer.translateBy(x: 36, y: 30)
            layer.rotate(by: .degrees(flat ? -40 : 0))
            layer.translateBy(x: -36, y: -30)
            let ear = Self.leftEar
            layer.fill(ear, with: cat)
            layer.stroke(ear, with: cat, style: StrokeStyle(lineWidth: 4, lineJoin: .round))
        }
        canvas.drawLayer { layer in
            layer.translateBy(x: 84, y: 30)
            layer.rotate(by: .degrees(flat ? 40 : twitch))
            layer.translateBy(x: -84, y: -30)
            let ear = Self.rightEar
            layer.fill(ear, with: cat)
            layer.stroke(ear, with: cat, style: StrokeStyle(lineWidth: 4, lineJoin: .round))
        }

        canvas.fill(Self.face, with: cat)
        canvas.stroke(Self.face, with: cat, style: StrokeStyle(lineWidth: 4, lineJoin: .round))

        let happy = state.reaction == .glee || state.reaction == .cheer
        if happy {
            var arcs = Path()
            arcs.move(to: CGPoint(x: 37.5, y: 48)); arcs.addQuadCurve(to: CGPoint(x: 52.5, y: 48), control: CGPoint(x: 45, y: 39))
            arcs.move(to: CGPoint(x: 67.5, y: 48)); arcs.addQuadCurve(to: CGPoint(x: 82.5, y: 48), control: CGPoint(x: 75, y: 39))
            canvas.stroke(arcs, with: eye, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        } else {
            let squint: CGFloat = state.reaction == .blink ? 0.08 : 1
            let lookUp: CGFloat = state.sniffing ? -2.4 : 0
            for x in [45.0, 75.0] {
                let eyeRect = CGRect(x: x - 7.4, y: 45 - 8.4 * squint, width: 14.8, height: 16.8 * squint)
                canvas.fill(Path(ellipseIn: eyeRect), with: eye)
                if squint > 0.5 {
                    let pupil = CGRect(x: x - 2.6, y: 45 - 6.2 + lookUp, width: 5.2, height: 12.4)
                    canvas.fill(Path(ellipseIn: pupil), with: .color(Palette.onAccent))
                }
            }
        }

        // Nose, scaled about its centre while sniffing.
        canvas.drawLayer { layer in
            layer.translateBy(x: 60, y: 57)
            layer.scaleBy(x: sniff.nose, y: sniff.nose)
            layer.translateBy(x: -60, y: -57)
            var nose = Path()
            nose.move(to: CGPoint(x: 55.5, y: 55)); nose.addLine(to: CGPoint(x: 64.5, y: 55)); nose.addLine(to: CGPoint(x: 60, y: 60.5)); nose.closeSubpath()
            layer.fill(nose, with: eye)
            layer.stroke(nose, with: eye, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        }
    }

    static let leftEar: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 25, y: 38))
        path.addLine(to: CGPoint(x: 27.5, y: 9.5))
        path.addQuadCurve(to: CGPoint(x: 32.1, y: 7.5), control: CGPoint(x: 28.1, y: 4.9))
        path.addLine(to: CGPoint(x: 52, y: 25))
        path.closeSubpath()
        return path
    }()

    static let rightEar: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 95, y: 38))
        path.addLine(to: CGPoint(x: 92.5, y: 9.5))
        path.addQuadCurve(to: CGPoint(x: 87.9, y: 7.5), control: CGPoint(x: 91.9, y: 4.9))
        path.addLine(to: CGPoint(x: 68, y: 25))
        path.closeSubpath()
        return path
    }()

    static let face: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 22, y: 88))
        path.addLine(to: CGPoint(x: 22, y: 52))
        path.addQuadCurve(to: CGPoint(x: 60, y: 22), control: CGPoint(x: 22, y: 24))
        path.addQuadCurve(to: CGPoint(x: 98, y: 52), control: CGPoint(x: 98, y: 24))
        path.addLine(to: CGPoint(x: 98, y: 88))
        path.closeSubpath()
        return path
    }()
}
