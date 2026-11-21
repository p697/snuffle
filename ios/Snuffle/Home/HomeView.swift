import SnuffleKit
import SwiftUI

/// 今日: the totals strip and one card per project. The refresh button lives in the tab bar.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    header
                    TotalsStrip()
                    ForEach(model.projects) { project in
                        NavigationLink(value: project.id) {
                            ProjectCard(project: project)
                        }
                        .buttonStyle(.plain)
                    }
                    if model.projects.isEmpty {
                        EmptyProjects()
                    }
                    if model.settings.demoMode {
                        Button {
                            model.update { $0.demoMode = false }
                        } label: {
                            (Text("现在看的是示例数据 · ") + Text(model.workspace.projects.isEmpty ? "连接真实项目" : "回到我的项目").bold().foregroundStyle(Palette.ink))
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.ink2)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("leaveDemo")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .clearsTabBar()
            .background(Palette.paper)
            .navigationDestination(for: UUID.self) { id in
                if let project = model.projects.first(where: { $0.id == id }) {
                    ProjectDetailView(project: project)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    /// 今日, then a short muted line beside it: "示例" in demo mode and when the last refresh was.
    private var header: some View {
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("今日")
                    .font(Typeface.title(40))
                    .foregroundStyle(Palette.ink)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        let status = status(now: context.date)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if model.settings.demoMode {
                                DemoMark()
                                if !status.isEmpty { Text("·").accessibilityHidden(true) }
                            }
                            Text(status).accessibilityIdentifier("refreshStatus")
                        }
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            Button {
                showSettings = true
            } label: {
                Image(systemName: "person")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 44, height: 44)
                    .background(Palette.card, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.line))
            }
            .accessibilityLabel("设置")
        }
        .padding(.horizontal, 4)
    }

    /// Empty before the first refresh: the button says what to do.
    private func status(now: Date) -> String {
        if model.isRefreshing { return "正在刷新…" }
        guard let last = model.lastRefresh else { return "" }
        let when = Format.ago(last, now: now)
        let count = model.refreshCountToday
        return count > 0 ? "\(when) · 第 \(count) 次" : when
    }
}

private struct DemoMark: View {
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(accent).frame(width: 6, height: 6)
            Text("示例").fontWeight(.semibold)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("示例数据")
    }
}

/// The three totals across every project. A delta pops in beside its label, so the strip never changes height.
struct TotalsStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent

    var body: some View {
        let totals = model.totals
        let mark = model.marksFading ? nil : model.totalsMark
        HStack(alignment: .top, spacing: 12) {
            tile("新增用户", value: totals.hasUsers ? Format.number(totals.newUsers) : "–", delta: mark.flatMap { $0.newUsers > 0 ? Format.delta(users: $0.newUsers) : nil })
            tile("收入", value: totals.hasRevenue ? Format.money(totals.revenue.rounded()) : "–", delta: mark.flatMap { $0.revenue > 0 ? Format.delta(money: $0.revenue) : nil })
            tile("待回复评论", value: totals.hasReviews ? Format.number(totals.reviewsToAnswer) : "–", delta: mark.flatMap { $0.reviews > 0 ? "+\($0.reviews)" : nil }, unit: totals.hasReviews ? "条" : nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Palette.strip, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func tile(_ label: String, value: String, delta: String?, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.stripMuted)
                    .lineLimit(1)
                // A wide delta (rare) squeezes the label rather than spilling into the next tile.
                DeltaChip(text: delta, visible: delta != nil, size: 12)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
            }
            .frame(height: 20, alignment: .leading)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Odometer(text: value, size: 30, color: Palette.stripText)
                if let unit {
                    Text(unit).font(.system(size: 12)).foregroundStyle(Palette.stripMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EmptyProjects: View {
    @State private var adding = false

    var body: some View {
        VStack(spacing: 12) {
            Text("还没有项目")
                .font(.system(size: 17, weight: .bold))
            Text("连上 PostHog 或商店后台，每次刷新都能看到新增用户、收入和评论。")
                .font(.system(size: 14))
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
            Button("添加第一个项目") { adding = true }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .sheet(isPresented: $adding) { AddProjectFlow() }
    }
}
