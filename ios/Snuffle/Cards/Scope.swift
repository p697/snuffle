import SnuffleKit
import SwiftUI

extension Project {
    /// "不含网站访客（未登录）" or "所有来源都算": the project's scope in one line.
    var scopeSummary: String {
        let left = Surface.allCases.filter(metrics.surfacesLeftOut.contains)
        guard !left.isEmpty else { return String(localized: "所有来源都算") }
        return String(localized: "不含\(left.map(\.title).formatted(.list(type: .and)))")
    }
}

/// "算哪些人", pushed from the metric library.
struct ScopePage: View {
    @Binding var project: Project

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BackButton()
                PageTitle(
                    title: String(localized: "算哪些人"),
                    subtitle: String(localized: "一个 PostHog 项目里常常既有 App，又有网站和官网访客。选哪些来源的人算进活跃、在线和页面浏览。")
                )
                ScopeOptions(project: $project)
            }
            .padding(16)
        }
        .sheetPage()
    }
}

/// The surfaces a project's PostHog events come from, each with its people in the last 30 days and a switch, and
/// what today's actives and the month's would be with the switches as they are.
struct ScopeOptions: View {
    @Binding var project: Project
    @Environment(AppModel.self) private var model
    @State private var stats: [SurfaceStat]?
    @State private var failed = false
    @State private var preview: [Metric: Double] = [:]
    @State private var measuring = false

    private static let previewMetrics: [Metric] = [.activeToday, .activeMonth]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardGroup {
                if stats == nil && !failed {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在看这个项目的事件从哪来").font(.system(size: 14)).foregroundStyle(Palette.ink2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                } else {
                    ForEach(Array(shown.enumerated()), id: \.element) { index, surface in
                        if index > 0 { RowDivider() }
                        surfaceRow(surface)
                    }
                }
            }
            if failed {
                note(String(localized: "没读到各来源的人数，开关照样有效。"))
            }
            previewCard
            note(String(localized: "活跃、在线、页面浏览和「开始使用」的新增用户按这里选的来源算，一个人在几处出现只算一次。注册事件、收入和自定义事件按事件本身算，不分来源。"))
        }
        .task(id: project.posthog?.projectId) { await loadStats() }
        .task(id: project.metrics.surfacesLeftOut) { await measure() }
    }

    /// Surfaces with people in the last 30 days, and any left out; every surface when the counts could not be read.
    private var shown: [Surface] {
        let seen = Set((stats ?? []).filter { $0.people > 0 }.map(\.surface))
        guard !seen.isEmpty else { return Surface.allCases }
        return Surface.allCases.filter { seen.contains($0) || project.metrics.surfacesLeftOut.contains($0) }
    }

    private func surfaceRow(_ surface: Surface) -> some View {
        let included = !project.metrics.surfacesLeftOut.contains(surface)
        // Something must be counted: the last surface still in stays in.
        let last = included && shown.filter { !project.metrics.surfacesLeftOut.contains($0) }.count == 1
        let people = stats?.first { $0.surface == surface }?.people
        return Toggle(isOn: Binding(get: { included }, set: { set(surface, included: $0) })) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: surface.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(included ? Palette.ink : Palette.ink2)
                Text(verbatim: surface.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if let people {
                    Text("近 30 天 \(Format.number(people)) 人")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.ink2)
                }
            }
            .padding(.vertical, 8)
        }
        .toggleStyle(InkToggleStyle())
        .disabled(last)
        .accessibilityHint(last ? String(localized: "至少要算一个来源") : "")
        .accessibilityIdentifier("surface-\(surface.rawValue)")
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("按这样算")
                .font(.system(size: 12, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Palette.ink2)
            HStack(alignment: .top, spacing: 12) {
                ForEach(Self.previewMetrics, id: \.self) { metric in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: metric.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink2)
                        if measuring && preview[metric] == nil {
                            ProgressView().controlSize(.small).frame(height: 32)
                        } else {
                            Text(verbatim: metric.text(preview[metric]))
                                .font(Typeface.number(28))
                                .foregroundStyle(Palette.ink)
                                .opacity(measuring ? 0.4 : 1)
                                .contentTransition(.numericText())
                                .environment(\.layoutDirection, .leftToRight)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12))
            .foregroundStyle(Palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
    }

    private func set(_ surface: Surface, included: Bool) {
        var left = project.metrics.surfacesLeftOut
        if included { left.remove(surface) } else { left.insert(surface) }
        project.metrics.excludedSurfaces = left
    }

    private func loadStats() async {
        failed = false
        do {
            stats = try await model.provider.surfaces(for: project)
        } catch {
            failed = true
        }
    }

    /// Today's actives and the month's with the switches as they are. Flipping several waits for a pause.
    private func measure() async {
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        var scoped = project
        scoped.metrics.excludedSurfaces = project.metrics.surfacesLeftOut
        measuring = true
        let values = try? await model.provider.measure(scoped, metrics: Set(Self.previewMetrics))
        // Switched again meanwhile: the newer read owns the preview.
        guard !Task.isCancelled else { return }
        measuring = false
        withAnimation(.snappy) { preview = values ?? [:] }
    }
}
