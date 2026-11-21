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

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("今日")
                    .font(Typeface.title(40))
                    .foregroundStyle(Palette.ink)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(status(now: context.date))
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink2)
                        .accessibilityIdentifier("refreshStatus")
                }
            }
            Spacer()
            if model.settings.demoMode {
                Text("示例数据")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.ink2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .overlay(Capsule().strokeBorder(Palette.line))
            }
            Button {
                showSettings = true
            } label: {
                Image(systemName: "person")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 44, height: 44)
                    .background(Palette.card, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.line))
            }
            .accessibilityLabel("设置")
        }
        .padding(.horizontal, 4)
    }

    private func status(now: Date) -> String {
        if model.isRefreshing { return "正在刷新…" }
        guard let last = model.lastRefresh else { return "还没刷新过 · 按下面的按钮" }
        let count = model.refreshCountToday
        let when = Format.ago(last, now: now) == "刚刚" ? "刚刚刷新" : "\(Format.ago(last, now: now))刷新"
        return count > 0 ? "\(when) · 今天第 \(count) 次" : when
    }
}

/// The three totals across every project. Deltas sit on their own reserved line under each number.
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
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 10, trailing: 18))
        .background(Palette.strip, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func tile(_ label: String, value: String, delta: String?, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.stripMuted)
            Odometer(text: value, size: 26, color: Palette.stripText)
            ZStack(alignment: .leading) {
                if let unit {
                    Text(unit).font(.system(size: 12)).foregroundStyle(Palette.stripMuted)
                }
                DeltaChip(text: delta, visible: delta != nil, size: 12)
            }
            .frame(height: 20)
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
