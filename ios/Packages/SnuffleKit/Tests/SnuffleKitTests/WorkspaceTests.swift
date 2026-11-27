import Foundation
import Testing
@testable import SnuffleKit

@Suite("Naming and finding projects")
struct WorkspaceTests {
    @Test func storeNamesLoseTheirTagline() {
        #expect(Project.shortName("Isaac Codex: TBOI Guide & Wiki") == "Isaac Codex")
        #expect(Project.shortName("Clawket - AI Pocket Coder") == "Clawket")
        #expect(Project.shortName("YouMind｜AI 创作") == "YouMind")
        #expect(Project.shortName("  Lumen Notes  ") == "Lumen Notes")
        // Too short to stand alone: keep the whole name.
        #expect(Project.shortName("Go: Run Tracker") == "Go: Run Tracker")
    }

    @Test func aStoreOnlyProjectIsFoundByItsPostHogTwin() {
        let account = UUID()
        let saved = Project(name: "Isaac Codex", tint: .ink, appStore: AppStoreLink(accountId: nil, appId: "6811008944", appName: "Isaac Codex: TBOI Guide & Wiki", bundleId: "com.isaaccodex.app"))
        let other = Project(name: "Clawket", tint: .coral, posthog: PostHogLink(accountId: account, projectId: 2, projectName: "Clawket", timeZone: "UTC"))
        let workspace = Workspace(projects: [saved, other])

        let incoming = Project(name: "Isaac Codex", tint: .ocean, posthog: PostHogLink(accountId: account, projectId: 1, projectName: "Isaac Codex", timeZone: "UTC"))
        #expect(workspace.sameProduct(as: incoming)?.id == saved.id)

        // A project that already reads PostHog cannot take a second one.
        let clawket = Project(name: "Clawket", tint: .ocean, posthog: PostHogLink(accountId: account, projectId: 3, projectName: "Clawket", timeZone: "UTC"))
        #expect(workspace.sameProduct(as: clawket) == nil)

        // Package names count as names.
        let play = Project(name: "", tint: .ink, googlePlay: GooglePlayLink(accountId: account, packageName: "com.isaaccodex.app"))
        #expect(workspace.sameProduct(as: play)?.id == saved.id)

        // Short names never match.
        let app = Project(name: "App", tint: .ink, posthog: PostHogLink(accountId: account, projectId: 4, projectName: "App", timeZone: "UTC"))
        #expect(workspace.sameProduct(as: app) == nil)
    }

    @Test func twoLookalikesAreLeftAlone() {
        let first = Project(name: "Lumen", tint: .ink, appStore: AppStoreLink(accountId: nil, appId: "1", appName: "Lumen", bundleId: "a.lumen"))
        let second = Project(name: "Lumen Pro", tint: .ink, appStore: AppStoreLink(accountId: nil, appId: "2", appName: "Lumen Pro", bundleId: "a.lumenpro"))
        let incoming = Project(name: "Lumen", tint: .ink, posthog: PostHogLink(accountId: UUID(), projectId: 1, projectName: "Lumen", timeZone: "UTC"))
        #expect(Workspace(projects: [first, second]).sameProduct(as: incoming) == nil)
    }

    @Test func projectsReadingASourceAreFound() {
        let saved = Project(name: "Clawket", tint: .ink, posthog: PostHogLink(accountId: UUID(), projectId: 337, projectName: "Default project", timeZone: "UTC"))
        let workspace = Workspace(projects: [saved])
        #expect(workspace.project(reading: .posthog, id: "337")?.id == saved.id)
        #expect(workspace.project(reading: .posthog, id: "338") == nil)
        #expect(workspace.project(reading: .appStore, id: "337") == nil)
    }

    @Test func aSecondProjectForTheSameProductMergesIntoTheFirst() {
        let account = UUID()
        let store = Project(name: "Isaac Codex", tint: .ocean, appStore: AppStoreLink(accountId: nil, appId: "1", appName: "Isaac Codex", bundleId: "a.isaac"), iconVersion: 2)
        var counting = MetricSettings.standard
        counting.activityEvent = "app_opened"
        counting.revenue = .posthogEvent(event: "purchase", valueProperty: "value")
        let tile = InsightTile(id: 9, name: "DAU", kind: .trends, query: .object([:]), dashboard: DashboardRef(id: 1, name: "Launch"))
        let incoming = Project(
            name: "Isaac Codex", tint: .coral,
            posthog: PostHogLink(accountId: account, projectId: 5, projectName: "Isaac Codex", timeZone: "UTC"),
            revenueCat: RevenueCatLink(accountId: account, projectId: "rc", projectName: "Isaac Codex"),
            metrics: counting, pins: [tile], dashboardChecked: true
        )
        let merged = store.merging(incoming)
        #expect(merged.id == store.id)
        #expect(merged.tint == .ocean)
        #expect(merged.iconVersion == 2)
        #expect(merged.platforms == [.posthog, .revenueCat, .appStore])
        #expect(merged.metrics.activityEvent == "app_opened")
        // Revenue already counted from PostHog events stays so; RevenueCat does not take over.
        #expect(merged.metrics.revenue == .posthogEvent(event: "purchase", valueProperty: "value"))
        #expect(merged.pins == [tile])
        #expect(merged.dashboardChecked)
        // The store-only card grows the people numbers the new source brings.
        #expect(merged.card == CardLayout.standard(for: merged))
        #expect(merged.card != store.card)
    }

    @Test func demoDashboardsCountThePeopleChartsTheWayARealOneDoes() async throws {
        let provider = DemoProvider(world: nil, latency: .zero) { _ in }
        let lumen = DemoWorld.projects[0]
        let list = try await provider.dashboards(for: lumen)
        #expect(list.map(\.name) == ["Product health", "Growth"])
        let detail = try await provider.dashboard(list[0].ref, for: lumen)
        let counting = try #require(DashboardReading.counting(detail))
        #expect(counting.activityEvent == "app_opened")
        #expect(counting.conditions == ["properties['environment'] = 'production'"])
        #expect(counting.isDeliberate)
        #expect(detail.tiles.filter(\.canDraw).count == 4)
        let result = try await provider.run(detail.tiles[0], for: lumen)
        guard case .bars(let labels, let series) = result.shape(for: detail.tiles[0]) else {
            Issue.record("expected bars")
            return
        }
        #expect(labels.count == 7)
        #expect(!series.isEmpty)
    }
}
