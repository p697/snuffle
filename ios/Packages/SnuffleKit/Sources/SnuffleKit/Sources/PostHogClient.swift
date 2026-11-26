import Foundation

public struct PostHogProject: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var timezone: String?
    public var organizationName: String?

    public init(id: Int, name: String, timezone: String?, organizationName: String?) {
        self.id = id
        self.name = name
        self.timezone = timezone
        self.organizationName = organizationName
    }

    /// The name to show and to suggest for a Snuffle project: PostHog calls a new organization's first project
    /// "Default project", which says nothing, so the organization's name stands in for it.
    public var displayName: String {
        guard name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Default project") == .orderedSame,
              let organizationName, !organizationName.isEmpty else { return name }
        return organizationName
    }
}

/// Reads a PostHog project with HogQL. Every number is one query; all timestamps are passed as Unix seconds so
/// "today" is decided by `ProjectClock`, not by whichever time zone the server assumes.
public struct PostHogClient: Sendable {
    public var host: URL
    public var token: @Sendable () async throws -> String
    public var http: HTTPClient

    public init(host: URL, http: HTTPClient = HTTPClient(), token: @escaping @Sendable () async throws -> String) {
        self.host = host
        self.http = http
        self.token = token
    }

    // MARK: Projects

    /// The signed-in person's email and every project they can open, across all their organizations.
    /// `/api/users/@me/` lists projects only for the current organization; the others are read one by one, and an
    /// organization the credential may not open is skipped rather than failing the whole list.
    public func account() async throws -> (email: String?, projects: [PostHogProject]) {
        let me: Me = try await http.decode(Me.self, try await request("api/users/@me/"), platform: .posthog)
        var organizations = [me.organization].compactMap { $0 }
        let others = (me.organizations ?? []).filter { other in !organizations.contains { $0.id == other.id } }
        organizations += await withTaskGroup(of: (Int, Me.Organization?).self) { group in
            for (index, other) in others.enumerated() {
                group.addTask {
                    let detail = try? await http.decode(Me.Organization.self, try await request("api/organizations/\(other.id)/"), platform: .posthog)
                    return (index, detail)
                }
            }
            var found: [(Int, Me.Organization)] = []
            for await (index, detail) in group {
                if let detail { found.append((index, detail)) }
            }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var result: [PostHogProject] = []
        var seen = Set<Int>()
        for organization in organizations {
            for team in (organization.teams ?? []) + (organization.projects ?? []) where !seen.contains(team.id) {
                seen.insert(team.id)
                result.append(PostHogProject(id: team.id, name: team.name, timezone: team.timezone, organizationName: organization.name))
            }
        }
        if result.isEmpty {
            // Older accounts: fall back to the project list of the current organization.
            struct Page: Decodable { let results: [Row] }
            struct Row: Decodable { let id: Int; let name: String; let timezone: String? }
            let page: Page = try await http.decode(Page.self, try await request("api/projects/"), platform: .posthog)
            result = page.results.map { PostHogProject(id: $0.id, name: $0.name, timezone: $0.timezone, organizationName: nil) }
        }
        return (me.email, result)
    }

    private struct Me: Decodable {
        let email: String?
        struct Organization: Decodable, Sendable {
            struct Team: Decodable, Sendable { let id: Int; let name: String; let timezone: String? }
            let id: String
            let name: String
            let teams: [Team]?
            let projects: [Team]?
        }
        let organization: Organization?
        let organizations: [Organization]?
    }

    /// The project's time zone, first day of the week and home dashboard, read fresh in case they were changed in
    /// PostHog.
    public func settings(projectId: Int) async throws -> (timeZone: String?, weekStartsMonday: Bool, primaryDashboard: Int?) {
        struct Row: Decodable { let timezone: String?; let week_start_day: Int?; let primary_dashboard: Int? }
        let row: Row = try await http.decode(Row.self, try await request("api/projects/\(projectId)/"), platform: .posthog)
        return (row.timezone, row.week_start_day == 1, row.primary_dashboard)
    }

    // MARK: Dashboards

    /// The project's dashboards, pinned ones first. Needs `dashboard:read`.
    public func dashboards(projectId: Int) async throws -> [DashboardSummary] {
        DashboardReading.summaries(try await http.decode(JSONValue.self, try await request("api/projects/\(projectId)/dashboards/?limit=200"), platform: .posthog))
    }

    /// One dashboard with the queries of its charts. Needs `dashboard:read` and `insight:read`.
    public func dashboard(projectId: Int, ref: DashboardRef) async throws -> DashboardDetail {
        DashboardReading.detail(try await http.decode(JSONValue.self, try await request("api/projects/\(projectId)/dashboards/\(ref.id)/"), platform: .posthog), ref: ref)
    }

    /// The counting the project's own dashboards use, to count that way from the start. The project's home dashboard
    /// says it best; without one, a project with a few dashboards takes the one with the most people charts. One with
    /// many (often one per feature or page) is left for the person to choose. Only a counting chosen on purpose is
    /// taken (`Counting.isDeliberate`). Nil when there is none; throws when the dashboards cannot be listed (an account
    /// connected before Snuffle read dashboards has no `dashboard:read`).
    public func dashboardCounting(projectId: Int) async throws -> DashboardReading.Counting? {
        let list = try await dashboards(projectId: projectId)
        func counting(_ summary: DashboardSummary) async -> DashboardReading.Counting? {
            guard let detail = try? await dashboard(projectId: projectId, ref: summary.ref),
                  let counting = DashboardReading.counting(detail), counting.isDeliberate else { return nil }
            return counting
        }
        if let home = try? await settings(projectId: projectId).primaryDashboard, let summary = list.first(where: { $0.id == home }),
           let found = await counting(summary) {
            return found
        }
        guard list.count <= 3 else { return nil }
        var best: DashboardReading.Counting?
        for summary in list {
            if let found = await counting(summary), found.sources.count > (best?.sources.count ?? 0) { best = found }
        }
        return best
    }

    /// Runs a saved insight's query as it is.
    public func run(projectId: Int, query: JSONValue, now: Date = Date()) async throws -> InsightResult {
        struct Body: Encodable { let query: JSONValue; let name: String }
        var request = try await request("api/projects/\(projectId)/query/")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(query: query, name: "snuffle_insight"))
        return InsightResult.parse(try await http.decode(JSONValue.self, request, platform: .posthog), at: now)
    }

    // MARK: Query

    public func query(projectId: Int, _ hogql: String, name: String) async throws -> [[JSONValue]] {
        struct Body: Encodable {
            struct Query: Encodable { let kind = "HogQLQuery"; let query: String }
            let query: Query
            let name: String
        }
        struct Response: Decodable { let results: [[JSONValue]]? }
        var request = try await request("api/projects/\(projectId)/query/")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(query: .init(query: hogql), name: name))
        let response: Response = try await http.decode(Response.self, request, platform: .posthog)
        return response.results ?? []
    }

    private func request(_ path: String) async throws -> URLRequest {
        var request = URLRequest(url: URL(string: path, relativeTo: host)!.absoluteURL)
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        return request
    }
}
