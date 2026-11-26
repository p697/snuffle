import Foundation

/// Google Play Developer API with the person's own Google sign-in. Google only lists reviews written or edited in
/// the last week, and only ones with text; `RefreshCache.land` keeps the ones read before, and older ones still
/// waiting for a reply are looked up again by id (`Review.toLookUp`).
public struct GooglePlayApp: Codable, Hashable, Sendable, Identifiable {
    public var packageName: String
    public var displayName: String
    public var id: String { packageName }

    public init(packageName: String, displayName: String) {
        self.packageName = packageName
        self.displayName = displayName
    }
}

public struct GooglePlayClient: Sendable {
    public static let base = URL(string: "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/")!
    static let reporting = "https://playdeveloperreporting.googleapis.com/v1beta1/"
    /// The most reviews a project keeps from Google Play, newest first, and the most one read fetches.
    public static let reviewLimit = 500
    public var accessToken: @Sendable () async throws -> String
    public var http: HTTPClient

    public init(http: HTTPClient = HTTPClient(), accessToken: @escaping @Sendable () async throws -> String) {
        self.http = http
        self.accessToken = accessToken
    }

    public func reviews(packageName: String, projectId: UUID) async throws -> [Review] {
        var all: [Review] = []
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "maxResults", value: "100")]
            if let pageToken { query.append(URLQueryItem(name: "token", value: pageToken)) }
            var request = URLRequest(url: Self.base.appending(path: "\(packageName)/reviews").appendingQuery(query))
            request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30
            let data = try await http.send(request, platform: .googlePlay)
            let page = try GooglePlayParsing.reviews(data, projectId: projectId)
            all += page.reviews
            pageToken = page.nextPageToken
        } while pageToken != nil && all.count < Self.reviewLimit
        return all
    }

    /// Every app the signed-in account can open in Play Console (Play Developer Reporting API), so nobody types a
    /// package name. Tokens granted before this scope was requested get a 403 here.
    public func apps() async throws -> [GooglePlayApp] {
        struct Page: Decodable {
            struct App: Decodable { let packageName: String; let displayName: String? }
            let apps: [App]?
            let nextPageToken: String?
        }
        var all: [GooglePlayApp] = []
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "pageSize", value: "1000")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            var request = URLRequest(url: URL(string: Self.reporting + "apps:search")!.appendingQuery(query))
            request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30
            let page = try await http.decode(Page.self, request, platform: .googlePlay)
            all += (page.apps ?? []).map { GooglePlayApp(packageName: $0.packageName, displayName: $0.displayName ?? $0.packageName) }
            pageToken = page.nextPageToken
        } while pageToken != nil && all.count < 5_000
        return all.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// The Android vitals among `metrics`, as Play Console shows them: the share of people who met a crash or an ANR
    /// while using the app, averaged over the 28 days up to the latest day Google has posted. A rate is missing when
    /// Google has no data for it (too few people). Two calls per rate: up to which day, then the value.
    public func vitals(packageName: String, metrics: Set<Metric>) async throws -> [Metric: Double] {
        try await withThrowingTaskGroup(of: (Metric, Double?).self) { group in
            for metric in metrics {
                guard let vital = metric.vital else { continue }
                group.addTask { (metric, try await rate(vital, packageName: packageName)) }
            }
            var values: [Metric: Double] = [:]
            for try await (metric, value) in group { values[metric] = value }
            return values
        }
    }

    private func rate(_ vital: Metric.Vital, packageName: String) async throws -> Double? {
        let set = Self.reporting + "apps/\(packageName)/\(vital.metricSet)"
        var request = URLRequest(url: URL(string: set)!)
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        guard let end = try GooglePlayParsing.latestDay(try await http.send(request, platform: .googlePlay)) else { return nil }

        request = URLRequest(url: URL(string: set + ":query")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "timelineSpec": ["aggregationPeriod": "DAILY", "startTime": end.dayBefore.json, "endTime": end.json],
            "metrics": [vital.metric]
        ])
        return try GooglePlayParsing.rate(try await http.send(request, platform: .googlePlay), metric: vital.metric)
    }

    /// One review by its id, at any age: Google lists only the last week's, but still answers for older ones by id.
    /// Nil once its writer deleted it.
    public func review(packageName: String, reviewId: String, projectId: UUID) async throws -> Review? {
        var request = URLRequest(url: Self.base.appending(path: "\(packageName)/reviews/\(reviewId)"))
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        do {
            return try GooglePlayParsing.review(try await http.send(request, platform: .googlePlay), projectId: projectId)
        } catch SourceError.http(_, 404, _) {
            return nil
        }
    }

    public func reply(packageName: String, reviewId: String, text: String) async throws {
        var request = URLRequest(url: Self.base.appending(path: "\(packageName)/reviews/\(reviewId):reply"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["replyText": text])
        _ = try await http.send(request, platform: .googlePlay)
    }
}

extension Metric {
    /// Where an Android vital is read: its metric set, and the metric Play Console shows and judges the app by.
    struct Vital: Sendable {
        var metricSet: String
        var metric: String
    }

    var vital: Vital? {
        switch self {
        case .crashRate: Vital(metricSet: "crashRateMetricSet", metric: "userPerceivedCrashRate28dUserWeighted")
        case .anrRate: Vital(metricSet: "anrRateMetricSet", metric: "userPerceivedAnrRate28dUserWeighted")
        default: nil
        }
    }
}

/// A review as the Play Developer API writes it, in a list or alone.
private struct PlayReview: Decodable {
    struct Comment: Decodable {
        struct Stamp: Decodable {
            let seconds: String?
            var date: Date? { seconds.flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:)) }
        }
        struct User: Decodable {
            struct Device: Decodable { let manufacturer: String?; let productName: String? }
            let text: String?
            let lastModified: Stamp?
            let starRating: Int?
            let reviewerLanguage: String?
            let appVersionName: String?
            let androidOsVersion: Int?
            let thumbsUpCount: Int?
            let deviceMetadata: Device?
        }
        struct Developer: Decodable { let text: String?; let lastModified: Stamp? }
        let userComment: User?
        let developerComment: Developer?
    }
    let reviewId: String
    let authorName: String?
    let comments: [Comment]?

    func review(projectId: UUID) -> Review? {
        guard let user = comments?.compactMap(\.userComment).first, let created = user.lastModified?.date else { return nil }
        let developer = comments?.compactMap(\.developerComment).first
        return Review(
            storeId: reviewId,
            platform: .googlePlay,
            projectId: projectId,
            rating: user.starRating ?? 0,
            body: (user.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            author: authorName,
            language: user.reviewerLanguage,
            createdAt: created,
            reply: developer?.text.map { ReviewReply(text: $0, date: developer?.lastModified?.date, pending: false) },
            appVersion: user.appVersionName?.nonEmpty,
            device: GooglePlayParsing.device(maker: user.deviceMetadata?.manufacturer, model: user.deviceMetadata?.productName),
            system: user.androidOsVersion.map(GooglePlayParsing.android),
            helpful: user.thumbsUpCount
        )
    }
}

public enum GooglePlayParsing {
    public static func reviews(_ data: Data, projectId: UUID) throws -> (reviews: [Review], nextPageToken: String?) {
        struct Page: Decodable {
            struct Pagination: Decodable { let nextPageToken: String? }
            let reviews: [PlayReview]?
            let tokenPagination: Pagination?
        }
        let page: Page
        do {
            page = try JSONDecoder().decode(Page.self, from: data)
        } catch {
            throw SourceError.invalidResponse(.googlePlay, "reviews")
        }
        return ((page.reviews ?? []).compactMap { $0.review(projectId: projectId) }, page.tokenPagination?.nextPageToken)
    }

    /// One review, as `reviews.get` answers.
    public static func review(_ data: Data, projectId: UUID) throws -> Review? {
        do {
            return try JSONDecoder().decode(PlayReview.self, from: data).review(projectId: projectId)
        } catch {
            throw SourceError.invalidResponse(.googlePlay, "review")
        }
    }

    /// "Samsung Galaxy S23", without naming the maker twice ("Google Pixel 8", not "Google Google Pixel 8").
    static func device(maker: String?, model: String?) -> String? {
        guard let model = model?.nonEmpty else { return maker?.nonEmpty }
        guard let maker = maker?.nonEmpty, !model.lowercased().hasPrefix(maker.lowercased()) else { return model }
        return maker.prefix(1).uppercased() + maker.dropFirst() + " " + model
    }

    /// "Android 14" for an API level; "API 37" for one newer than this table.
    static func android(_ apiLevel: Int) -> String {
        let versions = [21: "5.0", 22: "5.1", 23: "6", 24: "7.0", 25: "7.1", 26: "8.0", 27: "8.1", 28: "9", 29: "10", 30: "11", 31: "12", 32: "12L", 33: "13", 34: "14", 35: "15", 36: "16"]
        return versions[apiLevel].map { "Android \($0)" } ?? "API \(apiLevel)"
    }

    /// A calendar day as the Reporting API writes it; daily vitals are kept in Pacific time.
    struct Day: Equatable {
        var year: Int, month: Int, day: Int
        var timeZone = "America/Los_Angeles"

        var json: [String: Any] { ["year": year, "month": month, "day": day, "timeZone": ["id": timeZone]] }

        var dayBefore: Day {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZone) ?? .gmt
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day))!
            let before = calendar.dateComponents([.year, .month, .day], from: calendar.date(byAdding: .day, value: -1, to: date)!)
            return Day(year: before.year!, month: before.month!, day: before.day!, timeZone: timeZone)
        }
    }

    /// The end (exclusive) of the latest day Google has posted daily data for, from a metric set's `freshnessInfo`.
    static func latestDay(_ data: Data) throws -> Day? {
        struct MetricSet: Decodable {
            struct Freshness: Decodable {
                struct Stamp: Decodable {
                    struct Zone: Decodable { let id: String? }
                    let year: Int?, month: Int?, day: Int?
                    let timeZone: Zone?
                }
                let aggregationPeriod: String?
                let latestEndTime: Stamp?
            }
            struct Info: Decodable { let freshnesses: [Freshness]? }
            let freshnessInfo: Info?
        }
        let set: MetricSet
        do {
            set = try JSONDecoder().decode(MetricSet.self, from: data)
        } catch {
            throw SourceError.invalidResponse(.googlePlay, "vitals")
        }
        guard let end = set.freshnessInfo?.freshnesses?.first(where: { $0.aggregationPeriod == "DAILY" })?.latestEndTime,
              let year = end.year, let month = end.month, let day = end.day else { return nil }
        return Day(year: year, month: month, day: day, timeZone: end.timeZone?.id ?? "America/Los_Angeles")
    }

    /// `metric` on the last day the query returned, as a fraction (0.0109 is 1.09%); nil when Google has no data.
    static func rate(_ data: Data, metric: String) throws -> Double? {
        struct Response: Decodable {
            struct Row: Decodable {
                struct Value: Decodable {
                    struct Decimal: Decodable { let value: String? }
                    let metric: String?
                    let decimalValue: Decimal?
                }
                let metrics: [Value]?
            }
            let rows: [Row]?
        }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw SourceError.invalidResponse(.googlePlay, "vitals")
        }
        return response.rows?.last?.metrics?.first { $0.metric == metric }?.decimalValue?.value.flatMap(Double.init)
    }
}

extension String {
    fileprivate var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
