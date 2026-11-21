import Foundation

/// Google Play Developer API with the person's own Google sign-in. Google only returns reviews from the last 7 days.
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
        } while pageToken != nil && all.count < 500
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
            var request = URLRequest(url: URL(string: "https://playdeveloperreporting.googleapis.com/v1beta1/apps:search")!.appendingQuery(query))
            request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30
            let page = try await http.decode(Page.self, request, platform: .googlePlay)
            all += (page.apps ?? []).map { GooglePlayApp(packageName: $0.packageName, displayName: $0.displayName ?? $0.packageName) }
            pageToken = page.nextPageToken
        } while pageToken != nil && all.count < 5_000
        return all.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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

public enum GooglePlayParsing {
    public static func reviews(_ data: Data, projectId: UUID) throws -> (reviews: [Review], nextPageToken: String?) {
        struct Page: Decodable {
            struct Item: Decodable {
                struct Comment: Decodable {
                    struct Stamp: Decodable { let seconds: String? }
                    struct User: Decodable {
                        let text: String?
                        let lastModified: Stamp?
                        let starRating: Int?
                        let reviewerLanguage: String?
                    }
                    struct Developer: Decodable { let text: String?; let lastModified: Stamp? }
                    let userComment: User?
                    let developerComment: Developer?
                }
                let reviewId: String
                let authorName: String?
                let comments: [Comment]?
            }
            struct Pagination: Decodable { let nextPageToken: String? }
            let reviews: [Item]?
            let tokenPagination: Pagination?
        }
        let page: Page
        do {
            page = try JSONDecoder().decode(Page.self, from: data)
        } catch {
            throw SourceError.invalidResponse(.googlePlay, "reviews")
        }
        func date(_ stamp: Page.Item.Comment.Stamp?) -> Date? {
            stamp?.seconds.flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
        }
        let reviews = (page.reviews ?? []).compactMap { item -> Review? in
            guard let user = item.comments?.compactMap(\.userComment).first, let created = date(user.lastModified) else { return nil }
            let developer = item.comments?.compactMap(\.developerComment).first
            return Review(
                storeId: item.reviewId,
                platform: .googlePlay,
                projectId: projectId,
                rating: user.starRating ?? 0,
                body: (user.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                author: item.authorName,
                language: user.reviewerLanguage,
                createdAt: created,
                reply: developer?.text.map { ReviewReply(text: $0, date: date(developer?.lastModified), pending: false) }
            )
        }
        return (reviews, page.tokenPagination?.nextPageToken)
    }
}
