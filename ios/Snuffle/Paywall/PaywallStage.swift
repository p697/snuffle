import Charts
import SnuffleKit
import SwiftUI

/// The paywall's big preview: Pro drawn with the person's own projects and numbers.
struct PaywallStage: View {
    var page: PaywallPage
    var entry: TodayEntry
    @Environment(\.accent) private var accent

    var body: some View {
        ZStack {
            switch page {
            case .desk: HomeScreenPreview(entry: entry)
            case .lock: LockScreenPreview(entry: entry)
            case .history: HistoryPreview()
            case .projects: ProjectsPreview(entry: entry)
            }
        }
        .transition(.opacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(page == .lock ? LockScreenPreview.wallpaper : accent)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

// MARK: Home screen

/// A slice of a home screen: wallpaper, the widget in its real grid footprint among app icons, and the dock.
private struct HomeScreenPreview: View {
    var entry: TodayEntry
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var colorScheme
    @State private var size = Size.medium

    enum Size { case medium, small }

    /// Widget sizes on a 6.1-inch iPhone; the preview scales them to fit the stage.
    private static let medium = CGSize(width: 338, height: 158)
    private static let small = CGSize(width: 158, height: 158)
    private static let icon: CGFloat = 56
    private static let gutter: CGFloat = 24

    var body: some View {
        GeometryReader { geometry in
            let scale = min(1, (geometry.size.width - Self.gutter * 2) / Self.medium.width)
            ZStack {
                wallpaper
                VStack(spacing: 8) {
                    sizePicker
                    ViewThatFits(in: .vertical) {
                        screen(scale: scale, iconRow: true, dock: true)
                        screen(scale: scale, iconRow: false, dock: true)
                        screen(scale: scale, iconRow: false, dock: false)
                    }
                }
                .padding(.horizontal, Self.gutter)
                .padding(.vertical, 6)
            }
        }
    }

    private var dark: Bool { colorScheme == .dark }

    private var wallpaper: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.08)).frame(width: 280, height: 280).offset(x: 150, y: -150)
            Circle().fill(Color.white.opacity(0.28)).frame(width: 220, height: 220).offset(x: -150, y: 110)
            // The system dims the wallpaper in dark mode.
            if dark { Color.black.opacity(0.42) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    private var sizePicker: some View {
        HStack(spacing: 2) {
            sizeButton(.medium, "中号")
            sizeButton(.small, "小号")
        }
        .padding(3)
        .background(dark ? Color.black.opacity(0.35) : Color.white.opacity(0.5), in: Capsule())
    }

    private func sizeButton(_ value: Size, _ title: String) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { size = value }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(dark ? Palette.ink : Palette.onAccent)
                .padding(.horizontal, 18)
                .frame(minHeight: 34)
                .background(size == value ? (dark ? Palette.card : Color.white) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(size == value ? .isSelected : [])
        .accessibilityIdentifier("widgetSize-\(title)")
    }

    private func screen(scale: CGFloat, iconRow: Bool, dock: Bool) -> some View {
        let icon = Self.icon * scale
        let width = Self.medium.width * scale
        return VStack(spacing: 0) {
            switch size {
            case .medium:
                widget(Self.medium, scale: scale) {
                    TodayMediumFace(entry: entry) { refreshButton }
                }
            case .small:
                HStack(alignment: .top, spacing: 0) {
                    widget(Self.small, scale: scale) {
                        TodaySmallFace(entry: entry) { refreshButton }
                    }
                    Spacer(minLength: 0)
                    iconGrid(Self.grid, icon: icon, width: Self.small.width * scale)
                }
                .frame(width: width)
            }
            if iconRow {
                HStack(spacing: 0) {
                    ForEach(Self.row.indices, id: \.self) { index in
                        if index > 0 { Spacer(minLength: 0) }
                        HomeIcon(app: Self.row[index], size: icon)
                    }
                }
                .frame(width: width)
                .padding(.top, 12 * scale)
            }
            Spacer(minLength: 4)
            if dock { self.dock(icon: icon * 0.84, width: width) }
        }
    }

    /// A widget at its real point size, scaled down as a whole so text and spacing keep their proportions.
    private func widget(_ base: CGSize, scale: CGFloat, @ViewBuilder face: () -> some View) -> some View {
        face()
            .padding(16)
            .frame(width: base.width, height: base.height)
            .background(WidgetPalette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: base.width * scale, height: base.height * scale, alignment: .topLeading)
            .shadow(color: .black.opacity(0.14), radius: 9, y: 5)
    }

    /// Refreshes for real: the preview's numbers change the same way the widget's would.
    private var refreshButton: some View {
        Button {
            Task { await model.refreshAll() }
        } label: {
            WidgetRefreshCircle(accent: model.settings.accent)
        }
        .buttonStyle(.plain)
        .disabled(model.isRefreshing)
        .accessibilityLabel("刷新")
        .accessibilityIdentifier("previewRefresh")
    }

    private func iconGrid(_ apps: [HomeIcon.App], icon: CGFloat, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<2, id: \.self) { row in
                if row > 0 { Spacer(minLength: 0) }
                HStack(spacing: 0) {
                    HomeIcon(app: apps[row * 2], size: icon)
                    Spacer(minLength: 0)
                    HomeIcon(app: apps[row * 2 + 1], size: icon)
                }
            }
        }
        .frame(width: width, height: width)
    }

    private func dock(icon: CGFloat, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            MiniAppIcon(size: icon)
            ForEach(Self.dockApps.indices, id: \.self) { index in
                Spacer(minLength: 0)
                HomeIcon(app: Self.dockApps[index], size: icon)
            }
            Spacer(minLength: 0)
        }
        .frame(width: width + 20, height: icon + 14)
        .background(dark ? Color.white.opacity(0.14) : Color.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private static let row: [HomeIcon.App] = [
        .init(symbol: "calendar", color: ProjectTint.ocean.color),
        .init(symbol: "bubble.left.fill", color: ProjectTint.moss.color),
        .init(symbol: "camera.fill", color: ProjectTint.coral.color),
        .init(symbol: "music.note", color: ProjectTint.plum.color)
    ]
    private static let grid: [HomeIcon.App] = [
        .init(symbol: "map.fill", color: ProjectTint.moss.color),
        .init(symbol: "note.text", color: ProjectTint.cocoa.color),
        .init(symbol: "location.north.fill", color: ProjectTint.ocean.color),
        .init(symbol: "envelope.fill", color: Color(hex: 0x55554F))
    ]
    private static let dockApps: [HomeIcon.App] = [
        .init(symbol: "envelope.fill", color: Color(hex: 0x121210)),
        .init(symbol: "note.text", color: ProjectTint.cocoa.color),
        .init(symbol: "location.north.fill", color: ProjectTint.ocean.color)
    ]
}

/// A generic app icon: a coloured square with a plain glyph, so the scene reads as a home screen without
/// copying any real app.
private struct HomeIcon: View {
    struct App {
        var symbol: String
        var color: Color
    }

    var app: App
    var size: CGFloat

    var body: some View {
        Image(systemName: app.symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(app.color, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Snuffle's own icon in the dock: the refresh button with the cat's ears behind it.
private struct MiniAppIcon: View {
    var size: CGFloat
    @Environment(\.accent) private var accent

    var body: some View {
        ZStack {
            HStack(spacing: size * 0.2) {
                Ear().scale(x: -1, y: 1).fill(Color(hex: 0x121210))
                Ear().fill(Color(hex: 0x121210))
            }
            .frame(width: size * 0.52, height: size * 0.2)
            .offset(y: -size * 0.2)
            Circle().fill(accent).frame(width: size * 0.6, height: size * 0.6)
                .overlay(RefreshArrow().stroke(Palette.onAccent, style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round, lineJoin: .round)).frame(width: size * 0.32, height: size * 0.32))
                .offset(y: size * 0.07)
        }
        .frame(width: size, height: size)
        .background(Color(hex: 0xF4F4F1), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .accessibilityHidden(true)
    }

    /// A right ear tip; the left one is its mirror image.
    private struct Ear: Shape {
        nonisolated func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.75))
            path.closeSubpath()
            return path
        }
    }
}

// MARK: Lock screen

private struct LockScreenPreview: View {
    var entry: TodayEntry

    static let wallpaper = Color(light: 0x121210, dark: 0x26261F)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle().fill(Color.white.opacity(0.06)).frame(width: 300, height: 300).offset(x: -120, y: -120)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                LockInlineFace(entry: entry)
                    .font(.system(size: 14, weight: .semibold))
                Text(Date.now, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                    .font(.system(size: 80, weight: .bold).width(.condensed))
                    .accessibilityHidden(true)
                LockRectangularFace(entry: entry)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(width: 170)
                    .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                Spacer(minLength: 8)
                Text("锁屏有一行和三行两种")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: 30-day history

/// The project's real last 30 days, loaded when this page is first shown. The 23 days only Pro sees are grey.
private struct HistoryPreview: View {
    @Environment(AppModel.self) private var model
    @State private var points: [DailyPoint] = []
    @State private var name = ""
    @State private var failed: String?

    private static let days = 30
    private static let freeDays = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("每日新增用户").font(.system(size: 13, weight: .bold))
                Spacer()
                Text("\(name) · \(Self.days) 天").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink2).lineLimit(1)
            }
            ZStack {
                if let failed {
                    Text(failed).font(.system(size: 12.5)).foregroundStyle(Palette.ink2).multilineTextAlignment(.center)
                } else if points.isEmpty {
                    ProgressView()
                } else {
                    chart
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            legend
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
        .padding(20)
        .task { await load() }
    }

    private var chart: some View {
        let proDays = max(0, points.count - Self.freeDays)
        return Chart(Array(points.enumerated()), id: \.offset) { index, point in
            BarMark(x: .value("日期", point.day, unit: .day), y: .value("新增用户", point.newUsers ?? 0))
                .foregroundStyle(index < proDays ? Palette.faint : Palette.ink)
                .cornerRadius(2)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .accessibilityLabel("\(name) 最近 \(points.count) 天每日新增用户")
    }

    private var legend: some View {
        GeometryReader { geometry in
            let proWidth = geometry.size.width * CGFloat(Self.days - Self.freeDays) / CGFloat(Self.days)
            HStack(spacing: 3) {
                legendPart("Pro 多出的 \(Self.days - Self.freeDays) 天", color: Palette.faint, text: Palette.ink2).frame(width: proWidth - 3)
                legendPart("免费 \(Self.freeDays) 天", color: Palette.ink, text: Palette.ink)
            }
        }
        .frame(height: 20)
    }

    private func legendPart(_ title: String, color: Color, text: Color) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(text)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .overlay(alignment: .top) { color.frame(height: 2) }
    }

    /// The first project a refresh reads; with none yet, the demo world's sample, labelled as such.
    private func load() async {
        guard points.isEmpty else { return }
        guard let project = model.refreshable.first else {
            var random = SplitMix64(seed: 7)
            points = DemoWorld.make(now: .now, random: &random).history(for: DemoWorld.lumenId, days: Self.days)
            name = "示例"
            return
        }
        name = project.name
        do {
            points = try await model.provider.history(for: project, days: Self.days)
            if points.isEmpty { failed = "这个项目还没有可画的历史数据" }
        } catch {
            failed = "历史数据没拉到，稍后再看看"
        }
    }
}

// MARK: Projects

private struct ProjectsPreview: View {
    var entry: TodayEntry

    var body: some View {
        let rows = Array(entry.rows.prefix(AppModel.freeProjectLimit))
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    Text(row.monogram)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(row.tint.textColor)
                        .frame(width: 28, height: 28)
                        .background(row.tint.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(row.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(row.newUsers.map(Format.number) ?? "–").font(Typeface.number(24))
                }
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .heavy))
                    .frame(width: 28, height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [4, 3])))
                Text("第 \(rows.count + 1) 个、第 \(rows.count + 2) 个…").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 4)
                Text("Pro")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(hex: 0x121210), in: Capsule())
            }
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.onAccent, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
            Spacer(minLength: 0)
        }
        .padding(20)
    }
}
