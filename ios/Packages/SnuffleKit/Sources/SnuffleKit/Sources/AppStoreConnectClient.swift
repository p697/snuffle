import CryptoKit
import Foundation

public struct AppStoreApp: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var bundleId: String

    public init(id: String, name: String, bundleId: String) {
        self.id = id
        self.name = name
        self.bundleId = bundleId
    }
}

/// Signs App Store Connect API tokens on the device with the team key the person imported.
public struct AppStoreConnectToken: Sendable {
    public var issuerId: String
    public var keyId: String
    private let key: P256.Signing.PrivateKey

    public init(issuerId: String, keyId: String, privateKeyPEM: String) throws {
        self.issuerId = issuerId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keyId = keyId.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            throw SourceError.invalidKey(String(localized: "这不是有效的 .p8 密钥文件内容", bundle: .module))
        }
    }

    /// A JWT valid for 15 minutes (Apple allows at most 20).
    public func make(now: Date = .now) throws -> String {
        let header = ["alg": "ES256", "kid": keyId, "typ": "JWT"]
        let issued = Int(now.timeIntervalSince1970)
        let payload: [String: Any] = ["iss": issuerId, "iat": issued, "exp": issued + 900, "aud": "appstoreconnect-v1"]
        let signingInput = try Self.base64URL(JSONSerialization.data(withJSONObject: header, options: .sortedKeys))
            + "." + Self.base64URL(JSONSerialization.data(withJSONObject: payload, options: .sortedKeys))
        let signature = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + Self.base64URL(signature.rawRepresentation)
    }

    public var publicKey: P256.Signing.PublicKey { key.publicKey }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// App Store Connect: the team's apps, their customer reviews, and replies.
public struct AppStoreConnectClient: Sendable {
    public static let base = URL(string: "https://api.appstoreconnect.apple.com/")!
    public var token: AppStoreConnectToken
    public var http: HTTPClient

    public init(token: AppStoreConnectToken, http: HTTPClient = HTTPClient()) {
        self.token = token
        self.http = http
    }

    public func apps() async throws -> [AppStoreApp] {
        let data = try await http.send(try request("v1/apps", query: [
            URLQueryItem(name: "fields[apps]", value: "name,bundleId"),
            URLQueryItem(name: "limit", value: "200")
        ]), platform: .appStore)
        return try AppStoreParsing.apps(data)
    }

    /// The newest reviews (up to 200, one request) with their replies. "To answer" counts within this window.
    public func reviews(appId: String, projectId: UUID) async throws -> [Review] {
        let data = try await http.send(try request("v1/apps/\(appId)/customerReviews", query: [
            URLQueryItem(name: "sort", value: "-createdDate"),
            URLQueryItem(name: "limit", value: "200"),
            URLQueryItem(name: "include", value: "response"),
            URLQueryItem(name: "fields[customerReviewResponses]", value: "responseBody,lastModifiedDate,state")
        ]), platform: .appStore)
        return try AppStoreParsing.reviews(data, projectId: projectId)
    }

    /// Posts a public reply. Apple reviews it before it shows on the store, so it comes back as pending.
    public func reply(reviewId: String, text: String) async throws {
        let body: [String: Any] = [
            "data": [
                "type": "customerReviewResponses",
                "attributes": ["responseBody": text],
                "relationships": ["review": ["data": ["type": "customerReviews", "id": reviewId]]]
            ]
        ]
        var request = try request("v1/customerReviewResponses", query: [])
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await http.send(request, platform: .appStore)
    }

    private func request(_ path: String, query: [URLQueryItem]) throws -> URLRequest {
        var url = Self.base.appending(path: path)
        if !query.isEmpty { url = url.appendingQuery(query) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try token.make())", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        return request
    }
}

public enum AppStoreParsing {
    public static func apps(_ data: Data) throws -> [AppStoreApp] {
        struct Page: Decodable {
            struct Item: Decodable {
                struct Attributes: Decodable { let name: String; let bundleId: String }
                let id: String
                let attributes: Attributes
            }
            let data: [Item]
        }
        do {
            return try JSONDecoder().decode(Page.self, from: data).data.map {
                AppStoreApp(id: $0.id, name: $0.attributes.name, bundleId: $0.attributes.bundleId)
            }
        } catch {
            throw SourceError.invalidResponse(.appStore, "apps")
        }
    }

    public static func reviews(_ data: Data, projectId: UUID) throws -> [Review] {
        struct Page: Decodable {
            struct Item: Decodable {
                struct Attributes: Decodable {
                    let rating: Int
                    let title: String?
                    let body: String?
                    let reviewerNickname: String?
                    let createdDate: String
                    let territory: String?
                }
                struct Relationships: Decodable {
                    struct Response: Decodable {
                        struct Ref: Decodable { let id: String }
                        let data: Ref?
                    }
                    let response: Response?
                }
                let id: String
                let attributes: Attributes
                let relationships: Relationships?
            }
            struct Included: Decodable {
                struct Attributes: Decodable { let responseBody: String?; let lastModifiedDate: String?; let state: String? }
                let id: String
                let type: String
                let attributes: Attributes?
            }
            let data: [Item]
            let included: [Included]?
        }
        let page: Page
        do {
            page = try JSONDecoder().decode(Page.self, from: data)
        } catch {
            throw SourceError.invalidResponse(.appStore, "reviews")
        }
        let responses = Dictionary((page.included ?? []).filter { $0.type == "customerReviewResponses" }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return page.data.compactMap { item in
            guard let created = ISO8601.parse(item.attributes.createdDate) else { return nil }
            var reply: ReviewReply?
            if let id = item.relationships?.response?.data?.id, let response = responses[id], let text = response.attributes?.responseBody {
                reply = ReviewReply(
                    text: text,
                    date: response.attributes?.lastModifiedDate.flatMap(ISO8601.parse),
                    pending: response.attributes?.state == "PENDING_PUBLISH"
                )
            }
            return Review(
                storeId: item.id,
                platform: .appStore,
                projectId: projectId,
                rating: item.attributes.rating,
                title: item.attributes.title,
                body: item.attributes.body ?? "",
                author: item.attributes.reviewerNickname,
                territory: item.attributes.territory,
                createdAt: created,
                reply: reply
            )
        }
    }
}
