import SnuffleKit
import SwiftUI

/// What went wrong with the sources, said once for every project together: the note after a refresh, the status
/// line on 总览 and the dot on 项目. Sources the person muted (`AppSettings.mutedSources`) are left out; the numbers
/// read from them are still marked on the cards.
struct SourceProblem: Equatable {
    enum Kind: Equatable {
        /// Sources that failed for a passing reason: the next refresh tries again.
        case failed
        /// Sources that stay broken until the person signs in again.
        case signIn
        /// Every source of every project failed with no connection.
        case offline
    }

    var kind: Kind
    /// The sources it is about, in `Platform` order; empty when offline.
    var platforms: [Platform]
    /// The projects with those failures, in screen order.
    var projects: [UUID]
    /// When the numbers it holds back were last read: the earliest of them, or when offline the latest read of any.
    var stoppedAt: Date?

    /// Nil when nothing failed, or only muted sources did. A sign-in is named before passing failures.
    init?(projects: [Project], snapshot: (UUID) -> ProjectSnapshot?, muted: Set<Platform>) {
        let read = projects.compactMap { project in snapshot(project.id).map { (project: project, snapshot: $0) } }
        let failures = read.flatMap { item in item.snapshot.failures.map { (project: item.project, snapshot: item.snapshot, failure: $0) } }
        guard !failures.isEmpty else { return nil }
        // Nothing answered and nothing could be reached: one sentence instead of every source by name.
        let nothingAnswered = read.allSatisfy { Set($0.snapshot.failures.map(\.platform)).isSuperset(of: $0.project.platforms) }
        if nothingAnswered, failures.allSatisfy({ $0.failure.kind == .network }) {
            kind = .offline
            platforms = []
            self.projects = read.map(\.project.id)
            stoppedAt = read.compactMap { $0.snapshot.readAt.values.max() }.max()
            return
        }
        let told = failures.filter { !muted.contains($0.failure.platform) }
        let signIn = told.filter { $0.failure.kind?.needsSignIn == true }
        let named = signIn.isEmpty ? told : signIn
        guard !named.isEmpty else { return nil }
        kind = signIn.isEmpty ? .failed : .signIn
        platforms = Platform.allCases.filter { platform in named.contains { $0.failure.platform == platform } }
        var seen = Set<UUID>()
        self.projects = named.map(\.project.id).filter { seen.insert($0).inserted }
        stoppedAt = named.compactMap { $0.snapshot.readAt[$0.failure.platform] }.min()
    }

    /// "Google Play 和 RevenueCat".
    var names: String { ListFormatter.localizedString(byJoining: platforms.map(\.displayName)) }

    /// For the status line: "Google Play 没连上".
    var summary: String {
        switch kind {
        case .failed: String(localized: "\(names) 没连上")
        case .signIn: String(localized: "\(names) 要重新登录")
        case .offline: String(localized: "没联网")
        }
    }
}

/// The note above the tab bar.
enum RefreshNotice: Equatable {
    case problem(SourceProblem)
    /// 重试 was tapped: the projects are being read again.
    case retrying(SourceProblem)
    /// A retry read every source it tried.
    case fixed(SourceProblem)

    /// How long it stays before hiding itself; nil until closed. A sign-in waits for the person.
    var stay: Duration? {
        switch self {
        case .problem(let problem): problem.kind == .signIn ? nil : .seconds(6)
        case .retrying: nil
        case .fixed: .seconds(2.5)
        }
    }
}

/// The note itself: ink on paper turned over, a line or two, and at most one thing to do besides closing it.
struct RefreshNoticeBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent
    @Environment(RootSheets.self) private var sheets

    var body: some View {
        ZStack {
            if let notice = model.notice {
                content(notice)
                    .padding(.leading, 14)
                    .padding(.trailing, 4)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                    .foregroundStyle(Palette.stripText)
                    .background(Palette.strip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: Palette.shadow.opacity(0.22), radius: 14, y: 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("refreshNotice")
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.notice)
        .onChange(of: model.notice) { _, notice in
            guard let notice else { return }
            AccessibilityNotification.Announcement(Self.announcement(notice)).post()
        }
    }

    @ViewBuilder
    private func content(_ notice: RefreshNotice) -> some View {
        HStack(spacing: 10) {
            switch notice {
            case .problem(let problem):
                Image(systemName: Self.symbol(problem.kind))
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 24)
                    .accessibilityHidden(true)
                lines(Self.title(problem), Self.detail(problem))
                if problem.kind == .signIn {
                    if let target = signInTarget(problem) {
                        action(String(localized: "重新登录")) { sheets.openSignIn(to: target.platform, of: target.project) }
                    }
                } else {
                    action(String(localized: "重试")) { Task { await model.retry() } }
                }
                close
            case .retrying(let problem):
                ProgressView().controlSize(.small).tint(accent).frame(width: 24)
                lines(Self.retryingText(problem), nil)
            case .fixed(let problem):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Palette.up)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                lines(Self.fixedText(problem), problem.platforms.isEmpty ? nil : String(localized: "数字已经更新"))
            }
        }
    }

    private func lines(_ title: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 14, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.stripMuted)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func action(_ title: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(Palette.onAccent)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(accent, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityIdentifier("noticeAction")
    }

    private var close: some View {
        Button {
            model.dismissNotice()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.stripMuted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭提示")
        .accessibilityIdentifier("noticeClose")
    }

    private func signInTarget(_ problem: SourceProblem) -> (project: Project, platform: Platform)? {
        for id in problem.projects {
            guard let project = model.projects.first(where: { $0.id == id }), let snapshot = model.snapshot(id) else { continue }
            if let failure = snapshot.failures.first(where: { problem.platforms.contains($0.platform) && $0.kind?.needsSignIn == true }) {
                return (project, failure.platform)
            }
        }
        return nil
    }

    private static func symbol(_ kind: SourceProblem.Kind) -> String {
        switch kind {
        case .failed: "icloud.slash"
        case .signIn: "person.crop.circle.badge.exclamationmark"
        case .offline: "wifi.slash"
        }
    }

    private static func title(_ problem: SourceProblem) -> String {
        switch problem.kind {
        case .failed, .signIn: problem.summary
        case .offline:
            problem.stoppedAt.map { String(localized: "没联网，数字停在 \(Format.moment($0))") } ?? String(localized: "没联网，这次没读到")
        }
    }

    private static func detail(_ problem: SourceProblem) -> String? {
        switch problem.kind {
        case .failed:
            problem.stoppedAt.map { String(localized: "受影响的数字停在 \(Format.moment($0))，下次刷新会再试") } ?? String(localized: "这次没读到，下次刷新会再试")
        case .signIn: String(localized: "重新登录后，数字才会更新")
        case .offline: nil
        }
    }

    private static func retryingText(_ problem: SourceProblem) -> String {
        problem.platforms.isEmpty ? String(localized: "正在刷新…") : String(localized: "正在重试 \(problem.names)…")
    }

    private static func fixedText(_ problem: SourceProblem) -> String {
        problem.platforms.isEmpty ? String(localized: "数字已经更新") : String(localized: "\(problem.names) 连上了")
    }

    private static func announcement(_ notice: RefreshNotice) -> String {
        switch notice {
        case .problem(let problem): [title(problem), detail(problem)].compactMap { $0 }.joined(separator: "\n")
        case .retrying(let problem): retryingText(problem)
        case .fixed(let problem): fixedText(problem)
        }
    }
}

/// Under a number whose source did not answer: "停在 10:42", "没读到" or "要重新登录". Tapping it opens the
/// project's sources. A tap rather than a button, so VoiceOver reads it with the card it sits on, where opening the
/// sources is an action of the card.
struct StaleMark: View {
    var text: String
    var size: CGFloat = 12
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock").font(.system(size: size - 2, weight: .semibold)).accessibilityHidden(true)
            Text(text).font(.system(size: size, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(Palette.ink2)
        .contentShape(Rectangle())
        .onTapGesture { action?() }
        .allowsHitTesting(action != nil)
    }
}

extension ProjectSnapshot {
    /// What a number's mark says while a source it is read from fails; nil when it was read this time.
    func staleNote(for metric: Metric, in project: Project) -> String? {
        guard let failure = failure(of: metric, in: project) else { return nil }
        if failure.kind?.needsSignIn == true { return String(localized: "要重新登录") }
        guard self[metric] != nil, let read = readAt[failure.platform] else { return String(localized: "没读到") }
        return String(localized: "停在 \(Format.moment(read))")
    }
}
