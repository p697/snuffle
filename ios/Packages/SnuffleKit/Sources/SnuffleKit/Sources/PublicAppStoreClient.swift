import Foundation

/// An app as one storefront of the public App Store lists it.
public struct PublicApp: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var bundleId: String
    public var developer: String?
    public var icon: URL?
    /// The storefront's average rating; nil before the first one.
    public var rating: Double?
    public var ratingCount: Int

    public init(id: String, name: String, bundleId: String, developer: String? = nil, icon: URL? = nil, rating: Double? = nil, ratingCount: Int = 0) {
        self.id = id
        self.name = name
        self.bundleId = bundleId
        self.developer = developer
        self.icon = icon
        self.rating = rating
        self.ratingCount = ratingCount
    }
}

/// The public App Store, read without any key: finding an app, its rating in a storefront, and the newest reviews
/// written there. These are Apple's search and lookup API and its customer reviews feed: public and long-lived, but
/// the feed is undocumented and both are rate-limited, so a refresh reads at most `AppStoreLink.maxCountries`.
public struct PublicAppStoreClient: Sendable {
    public static let base = URL(string: "https://itunes.apple.com/")!
    /// Large storefronts to look for an app's ratings in, after the phone's own.
    static let largeStorefronts = ["us", "cn", "jp", "gb", "de", "fr", "kr", "ca", "au", "br", "it", "es"]

    public var http: HTTPClient

    public init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    /// The apps for what the person typed. A name is searched in the phone's storefront (`home`) and the US one
    /// together, since many apps are not sold everywhere (AI apps often not in mainland China, where a search still
    /// lists look-alikes); names containing it come first. An App Store link is looked up in the storefront it names
    /// first, then like an app id typed on its own: in `home`, then the US.
    public func find(_ text: String, home: String) async throws -> [PublicApp] {
        let stores = Self.unique([home, "us"])
        if let id = Self.appId(in: text) {
            for country in Self.unique([Self.storefront(in: text)].compactMap { $0 } + stores) {
                if let app = try await lookup(appId: id, country: country) { return [app] }
            }
            return []
        }
        let results = await withTaskGroup(of: (Int, Result<[PublicApp], Error>).self) { group in
            for (index, country) in stores.enumerated() {
                group.addTask {
                    do { return (index, .success(try await search(text, country: country))) } catch { return (index, .failure(error)) }
                }
            }
            var results: [(Int, Result<[PublicApp], Error>)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let lists = results.compactMap { try? $0.get() }
        // Only when every storefront failed is there nothing to show.
        if lists.isEmpty, case .failure(let error)? = results.first { throw error }
        return Self.merge(lists, term: text)
    }

    /// Up to 25 apps matching `term` in `country`'s storefront, as Apple ranks them.
    func search(_ term: String, country: String) async throws -> [PublicApp] {
        let data = try await send(Self.base.appending(path: "search").appendingQuery([
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: "25")
        ]))
        return try PublicAppStoreParsing.apps(data)
    }

    /// The app in `country`'s storefront; nil when it is not sold there.
    public func lookup(appId: String, country: String) async throws -> PublicApp? {
        let data = try await send(Self.base.appending(path: "lookup").appendingQuery([
            URLQueryItem(name: "id", value: appId),
            URLQueryItem(name: "country", value: country)
        ]))
        return try PublicAppStoreParsing.apps(data).first
    }

    /// The newest reviews written in each of `countries` (up to 50 each, a request each), read together. One country
    /// that fails fails them all, so the reviews kept from the last read are never replaced by a part of them.
    public func reviews(appId: String, countries: [String], projectId: UUID) async throws -> [Review] {
        try await withThrowingTaskGroup(of: [Review].self) { group in
            for country in countries {
                group.addTask {
                    guard let url = Self.reviewsFeed(appId: appId, country: country) else { return [] }
                    return try PublicAppStoreParsing.reviews(try await send(url), country: country, projectId: projectId)
                }
            }
            var all: [Review] = []
            for try await part in group { all += part }
            var seen = Set<String>()
            return all.filter { seen.insert($0.storeId).inserted }.sorted { $0.createdAt > $1.createdAt }
        }
    }

    /// The average rating across `countries`, weighted by how many ratings each has; nil before the first.
    public func rating(appId: String, countries: [String]) async throws -> Double? {
        let apps = try await withThrowingTaskGroup(of: PublicApp?.self) { group in
            for country in countries { group.addTask { try await lookup(appId: appId, country: country) } }
            var apps: [PublicApp] = []
            for try await app in group { if let app { apps.append(app) } }
            return apps
        }
        return Self.average(apps)
    }

    /// The storefronts among `candidates` where the app has the most ratings, at most `AppStoreLink.maxCountries`,
    /// read together once when an app is linked. An app nobody rated yet gets the first candidate that sells it; one
    /// on no storefront yet (not released) gets none. A storefront that does not answer is left out.
    public func storefronts(appId: String, candidates: [String]) async -> [String] {
        let found = await withTaskGroup(of: (Int, PublicApp?).self) { group in
            for (index, country) in candidates.enumerated() {
                group.addTask { (index, try? await lookup(appId: appId, country: country)) }
            }
            var found: [(index: Int, count: Int)] = []
            for await (index, app) in group { if let app { found.append((index, app.ratingCount)) } }
            return found
        }
        let rated = found.filter { $0.count > 0 }.sorted { ($0.count, -$0.index) > ($1.count, -$1.index) }
        let picked = rated.isEmpty ? Array(found.sorted { $0.index < $1.index }.prefix(1)) : Array(rated.prefix(AppStoreLink.maxCountries))
        return picked.map { candidates[$0.index] }
    }

    /// The phone's storefront first, then the large ones.
    public static func candidates(region: String?) -> [String] {
        let own = region.map { $0.lowercased() }.flatMap { Territory.storefronts.contains($0) ? $0 : nil }
        return unique([own].compactMap { $0 } + largeStorefronts)
    }

    /// Each storefront's results in turn, each app once (as the first storefront lists it), at most 25; the ones whose
    /// name contains `term` first.
    static func merge(_ lists: [[PublicApp]], term: String) -> [PublicApp] {
        var seen = Set<String>()
        let all = lists.joined().filter { seen.insert($0.id).inserted }
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = { (app: PublicApp) in app.name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil }
        return Array((all.filter(named) + all.filter { !named($0) }).prefix(25))
    }

    /// The id in an App Store link ("apps.apple.com/cn/app/name/id1234567890") or typed on its own.
    static func appId(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 6, trimmed.allSatisfy(\.isASCIIDigit) { return trimmed }
        guard trimmed.contains("apple.com"), let match = trimmed.firstMatch(of: #/\/id(\d{6,})/#) else { return nil }
        return String(match.1)
    }

    /// The storefront an App Store link names ("apps.apple.com/jp/app/…"), if any.
    static func storefront(in text: String) -> String? {
        guard let match = text.firstMatch(of: #/(?:apps|itunes)\.apple\.com\/([a-zA-Z]{2})\//#) else { return nil }
        let code = match.1.lowercased()
        return Territory.storefronts.contains(code) ? code : nil
    }

    private static func unique(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        return codes.filter { seen.insert($0).inserted }
    }

    static func reviewsFeed(appId: String, country: String) -> URL? {
        guard appId.allSatisfy(\.isASCIIDigit), country.count == 2, country.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return URL(string: "\(country.lowercased())/rss/customerreviews/page=1/id=\(appId)/sortby=mostrecent/json", relativeTo: base)
    }

    static func average(_ apps: [PublicApp]) -> Double? {
        let rated = apps.compactMap { app in app.rating.map { (rating: $0, count: Double(app.ratingCount)) } }.filter { $0.count > 0 }
        let count = rated.map(\.count).reduce(0, +)
        return count > 0 ? rated.map { $0.rating * $0.count }.reduce(0, +) / count : nil
    }

    /// Apple turns too many requests away with a 403 here: nothing to sign in to, so it counts as rate limiting.
    private func send(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        do {
            return try await http.send(request, platform: .appStore)
        } catch SourceError.forbidden(.appStore, _), SourceError.unauthorized(.appStore) {
            throw SourceError.rateLimited(.appStore)
        }
    }
}

public enum PublicAppStoreParsing {
    /// Search and lookup results that are iPhone and iPad apps.
    public static func apps(_ data: Data) throws -> [PublicApp] {
        struct Page: Decodable {
            struct Item: Decodable {
                let wrapperType: String?
                let trackId: Int?
                let trackName: String?
                let bundleId: String?
                let artistName: String?
                let artworkUrl100: String?
                let averageUserRating: Double?
                let userRatingCount: Int?
            }
            let results: [Item]
        }
        let page: Page
        do {
            page = try JSONDecoder().decode(Page.self, from: data)
        } catch {
            throw SourceError.invalidResponse(.appStore, "search")
        }
        return page.results.compactMap { item in
            guard item.wrapperType == "software", let id = item.trackId, let name = item.trackName, let bundleId = item.bundleId else { return nil }
            let count = item.userRatingCount ?? 0
            return PublicApp(
                id: String(id),
                name: name,
                bundleId: bundleId,
                developer: item.artistName,
                icon: item.artworkUrl100.flatMap(URL.init(string:)),
                rating: count > 0 ? item.averageUserRating : nil,
                ratingCount: count
            )
        }
    }

    /// The customer reviews feed of one storefront. Its `entry` is a list, a single object when there is one review,
    /// and missing when there are none.
    public static func reviews(_ data: Data, country: String, projectId: UUID) throws -> [Review] {
        struct Label: Decodable { let label: String }
        struct Entry: Decodable {
            struct Author: Decodable { let name: Label? }
            let id: Label?
            let title: Label?
            let content: Label?
            let author: Author?
            let updated: Label?
            let rating: Label?
            let version: Label?
            enum CodingKeys: String, CodingKey {
                case id, title, content, author, updated
                case rating = "im:rating"
                case version = "im:version"
            }
        }
        struct Entries: Decodable {
            let items: [Entry]
            init(from decoder: Decoder) throws {
                if let list = try? [Entry](from: decoder) { items = list } else { items = [try Entry(from: decoder)] }
            }
        }
        struct Feed: Decodable {
            struct Body: Decodable { let entry: Entries? }
            let feed: Body
        }
        let feed: Feed
        do {
            feed = try JSONDecoder().decode(Feed.self, from: data)
        } catch {
            throw SourceError.invalidResponse(.appStore, "reviews")
        }
        let territory = Territory.alpha3(fromAlpha2: country)
        return (feed.feed.entry?.items ?? []).compactMap { entry in
            guard let id = entry.id?.label, let rating = entry.rating.flatMap({ Int($0.label) }),
                  let date = entry.updated.flatMap({ ISO8601.parse($0.label) }) else { return nil }
            return Review(
                storeId: id,
                platform: .appStore,
                projectId: projectId,
                rating: rating,
                title: entry.title?.label,
                body: entry.content?.label ?? "",
                author: entry.author?.name?.label,
                territory: territory,
                createdAt: date,
                appVersion: entry.version?.label,
                keyless: true
            )
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
