import SnuffleKit
import SwiftUI

/// A project's sources, opened from a number marked "停在 10:42": when each was last read, which numbers on the card
/// it gives, retrying or signing in to one that failed, and whether to be told when one fails.
struct SourcesSheet: View {
    var projectId: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var signingIn: Platform?

    var body: some View {
        ScrollView {
            if let project = model.projects.first(where: { $0.id == projectId }) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(project.name) 的数据来源")
                            .font(.system(size: 21, weight: .heavy))
                            .foregroundStyle(Palette.ink)
                        Text("每次刷新，这几个平台各读一次。没连上的那个，用到它的数字会停在上次读到的时间。")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink2)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    CardGroup {
                        ForEach(Array(project.platforms.enumerated()), id: \.element) { index, platform in
                            if index > 0 { RowDivider() }
                            row(platform, of: project)
                        }
                    }
                    SectionLabel(String(localized: "没连上时提醒我"))
                    CardGroup {
                        ForEach(project.platforms) { platform in
                            Toggle(isOn: reminder(platform)) { Text(verbatim: platform.displayName) }
                                .toggleStyle(InkToggleStyle())
                                .accessibilityIdentifier("remind-\(platform.rawValue)")
                        }
                    }
                    Text("关掉后，这个平台没连上时不再弹提示，用到它的数字下面仍会写停在几点。")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                    Button("好") { dismiss() }
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.top, 4)
                }
                .padding(20)
                .sheet(item: $signingIn) { platform in ReconnectSheet(project: project, platform: platform) }
            }
        }
        .background(Palette.paper.ignoresSafeArea())
        .presentationDragIndicator(.visible)
    }

    private func row(_ platform: Platform, of project: Project) -> some View {
        let snapshot = model.snapshot(project.id)
        let failure = snapshot?.failures.first { $0.platform == platform }
        let uses = Self.uses(platform, in: project)
        return HStack(spacing: 12) {
            PlatformLogo(platform: platform, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(platform.displayName).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                if let failure {
                    Text(failure.message).font(.system(size: 12)).foregroundStyle(Palette.warn).lineLimit(2)
                } else if let read = snapshot?.readAt[platform] {
                    Text("\(Format.ago(read))读到").font(.system(size: 12)).foregroundStyle(Palette.ink2)
                }
                if !uses.isEmpty {
                    Text("用在：\(uses)").font(.system(size: 12)).foregroundStyle(Palette.ink2).lineLimit(2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing(platform, failure: failure, project: project)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func trailing(_ platform: Platform, failure: SourceFailure?, project: Project) -> some View {
        if model.isRefreshing, model.stage(project.id) != .rest {
            ProgressView().controlSize(.small).frame(minWidth: 44, minHeight: 44)
        } else if let failure {
            let signIn = failure.kind?.needsSignIn == true
            Button(signIn ? String(localized: "重新登录") : String(localized: "重试")) {
                if signIn {
                    signingIn = platform
                } else {
                    Task { await model.retry([project.id]) }
                }
            }
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .overlay(Capsule().strokeBorder(Palette.ink, lineWidth: 1.5))
            .frame(minHeight: 44)
            .buttonStyle(.plain)
            .fixedSize()
        } else {
            Label("已连上", systemImage: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.up)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func reminder(_ platform: Platform) -> Binding<Bool> {
        Binding(get: { !model.settings.mutedSources.contains(platform) }, set: { model.setReminder($0, for: platform) })
    }

    /// The numbers on the card read from `platform`: "累计用户、今日活跃和收入".
    private static func uses(_ platform: Platform, in project: Project) -> String {
        var seen = Set<String>()
        let titles = project.card.visible(in: project).metrics
            .filter { $0.platforms(in: project).contains(platform) }
            .map { $0.title(in: project) }
            .filter { seen.insert($0).inserted }
        return ListFormatter.localizedString(byJoining: titles)
    }
}

/// Connects one source of a saved project, a new one or signing in to one again, then saves and reads the project.
struct ReconnectSheet: View {
    var project: Project
    var platform: Platform
    /// False when the dashboard sheet asked for the sign-in, so PostHog does not offer the dashboards a second time.
    var offersDashboards = true
    @Environment(AppModel.self) private var model
    @State private var draft: Project
    @State private var finished = false

    init(project: Project, platform: Platform, offersDashboards: Bool = true) {
        self.project = project
        self.platform = platform
        self.offersDashboards = offersDashboards
        _draft = State(initialValue: project)
    }

    var body: some View {
        // A sign-in to the same account can leave the link as it was: finishing is what counts, not a change.
        ConnectSourceSheet(platform: platform, project: Binding(get: { draft }, set: { draft = $0; finished = true }), offersDashboards: offersDashboards)
            .onDisappear {
                guard finished else { return }
                model.save(project: draft)
                Task { await model.refresh([draft], trigger: .project) }
            }
    }
}
