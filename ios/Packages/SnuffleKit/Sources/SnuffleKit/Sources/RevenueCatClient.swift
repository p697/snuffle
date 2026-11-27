import Foundation

public struct RevenueCatProject: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// RevenueCat API v2 with a secret key. Charts & Metrics allow 25 requests a minute, so a refresh makes one revenue call
/// (the daily chart, which holds every window) and reads the overview at most once an hour.
public struct RevenueCatClient: Sendable {
    public static let base = URL(string: "https://api.revenuecat.com/v2/")!
    public var secretKey: String
    public var http: HTTPClient

    public init(secretKey: String, http: HTTPClient = HTTPClient()) {
        self.secretKey = secretKey
        self.http = http
    }

    public func projects() async throws -> [RevenueCatProject] {
        struct Page: Decodable {
            struct Item: Decodable { let id: String; let name: String }
            let items: [Item]
        }
        let page: Page = try await http.decode(Page.self, request("projects", query: [URLQueryItem(name: "limit", value: "100")]), platform: .revenueCat)
        return page.items.map { RevenueCatProject(id: $0.id, name: $0.name) }
    }

    /// Gross revenue and transactions on one UTC calendar date, in USD.
    public struct DaySales: Equatable, Sendable {
        public var revenue: Double = 0
        /// Nil when the chart has no transactions measure.
        public var transactions: Double?
    }

    /// Revenue and transactions per UTC calendar date from the Charts API, keyed "yyyy-MM-dd". One request for the
    /// whole range; today, still incomplete, holds its running total, as the revenue metric does.
    public func dailySales(projectId: String, from: String, to: String) async throws -> [String: DaySales] {
        let chart: Chart = try await http.decode(Chart.self, request("projects/\(projectId)/charts/revenue", query: [
            URLQueryItem(name: "start_date", value: from),
            URLQueryItem(name: "end_date", value: to),
            URLQueryItem(name: "resolution", value: "0"),
            URLQueryItem(name: "currency", value: "USD")
        ]), platform: .revenueCat)
        return Self.dailySales(from: chart)
    }

    struct Chart: Decodable {
        struct Measure: Decodable { let display_name: String }
        struct Value: Decodable { let cohort: Double; let measure: Int; let value: Double? }
        let measures: [Measure]?
        let values: [Value]
    }

    /// Values come as one row per day and measure, found by name; revenue falls back to the first measure.
    static func dailySales(from chart: Chart) -> [String: DaySales] {
        let names = chart.measures?.map { $0.display_name.lowercased() } ?? []
        let revenueMeasure = names.firstIndex(of: "revenue") ?? 0
        let transactionsMeasure = names.firstIndex(of: "transactions")
        var byDay: [String: DaySales] = [:]
        for value in chart.values {
            let day = utcDate(Date(timeIntervalSince1970: value.cohort))
            if value.measure == revenueMeasure {
                byDay[day, default: DaySales()].revenue += value.value ?? 0
            } else if value.measure == transactionsMeasure {
                byDay[day, default: DaySales()].transactions = (byDay[day]?.transactions ?? 0) + (value.value ?? 0)
            }
        }
        return byDay
    }

    /// The windows (`SalesWindows`) of the UTC dates through `today`, from `dailySales` reaching
    /// `SalesWindows.lookbackDays` back.
    static func windows(_ byDay: [String: DaySales], today: Date) -> SalesWindows {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let days = (0..<SalesWindows.lookbackDays).map { byDay[utcDate(calendar.date(byAdding: .day, value: -$0, to: today)!)] ?? DaySales() }
        let counted = days.contains { $0.transactions != nil }
        return SalesWindows(newestFirst: days.map { ($0.revenue, counted ? $0.transactions ?? 0 : nil) })
    }

    public func overview(projectId: String) async throws -> SubscriptionOverview {
        struct Response: Decodable {
            struct Metric: Decodable { let id: String; let value: Double }
            let metrics: [Metric]
        }
        let response: Response = try await http.decode(Response.self, request("projects/\(projectId)/metrics/overview", query: [
            URLQueryItem(name: "currency", value: "USD")
        ]), platform: .revenueCat)
        return Self.overview(from: response.metrics.map { ($0.id, $0.value) })
    }

    static func overview(from metrics: [(String, Double)]) -> SubscriptionOverview {
        let byId = Dictionary(metrics, uniquingKeysWith: { first, _ in first })
        return SubscriptionOverview(
            mrr: byId["mrr"],
            activeSubscriptions: byId["active_subscriptions"].map { Int($0) },
            activeTrials: byId["active_trials"].map { Int($0) },
            revenueLast28Days: byId["revenue"]
        )
    }

    private func request(_ path: String, query: [URLQueryItem]) -> URLRequest {
        var request = URLRequest(url: Self.base.appending(path: path).appendingQuery(query))
        request.setValue("Bearer \(secretKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        return request
    }

    /// RevenueCat reports by UTC calendar date.
    public static func utcDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}
