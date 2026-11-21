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

    /// 今日, the way out of demo mode, then a short muted line with when the last refresh was.
    private var header: some View {
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("今日")
                    .font(Typeface.title(40))
                    .foregroundStyle(Palette.ink)
                if model.settings.demoMode {
                    LeaveDemoButton()
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(status(now: context.date)).accessibilityIdentifier("refreshStatus")
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

/// "● 示例 退出": says the numbers are made up, and is the way back, where the eye already is.
private struct LeaveDemoButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent

    var body: some View {
        Button {
            model.update { $0.demoMode = false }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(accent).frame(width: 7, height: 7)
                Text("示例").foregroundStyle(Palette.ink2)
                Text("退出").fontWeight(.bold).foregroundStyle(Palette.ink)
                Image(systemName: "xmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Palette.ink)
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Palette.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.line))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(model.workspace.projects.isEmpty ? "正在看示例数据，退出并连接真实项目" : "正在看示例数据，退出并回到我的项目")
        .accessibilityIdentifier("leaveDemo")
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
