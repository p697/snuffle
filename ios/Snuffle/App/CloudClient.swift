import Foundation
import Security
import SnuffleKit

/// Switches for features that ship in the code but not in the UI.
enum Feature {
    /// "帮我起草" (AI-drafted review replies). Off so the app can ship in mainland China, where generative AI
    /// features need their own filing. With it off nothing reaches Snuffle's server. Turning it back on also means
    /// restoring the collected data types in PrivacyInfo.xcprivacy, the drafting sections of site/public/privacy
    /// and terms, the App Store privacy answers, the Pro copy in App Store Connect, and a drafting page in
    /// `PaywallPage` (its `.drafts` reason opens on the widgets for now).
    static let replyDrafts = false
}

/// A drafted review reply: the text to post, and a Chinese rendering when the review is in another language.
nonisolated struct ReplyDraft: Codable, Equatable {
    var reply: String
    var translation: String?
    var language: String?
    /// True for demo mode's canned drafts, which never reach the model. Not part of the server's answer.
    var isSample = false

    private enum CodingKeys: String, CodingKey {
        case reply, translation, language
    }

    static func demo(for review: Review, appName: String) -> ReplyDraft {
        let name = review.author.map { "Hi \($0), " } ?? "Hi, "
        if review.rating <= 3 {
            return ReplyDraft(
                reply: name + "thank you for taking the time to tell us. We're sorry \(appName) let you down here. We're looking into it now and will ship a fix in the next update. If you write to support@example.com we can help you right away.",
                translation: "你好，谢谢你花时间告诉我们。很抱歉 \(appName) 在这里让你失望了。我们正在排查，会在下个版本修复。如果你写信到 support@example.com，我们可以马上帮你处理。",
                language: "en",
                isSample: true
            )
        }
        return ReplyDraft(
            reply: name + "thank you so much for the kind words! It means a lot to our small team. If there's anything you'd like to see next in \(appName), just let us know.",
            translation: "你好，非常感谢你的好评！这对我们这个小团队意义很大。如果你希望 \(appName) 接下来加什么功能，随时告诉我们。",
            language: "en",
            isSample: true
        )
    }
}

enum CloudError: Error, LocalizedError, Equatable {
    case notConfigured
    /// The server did not accept the Pro proof; the message says why (no subscription, shared too widely…).
    case proRequired(String)
    case limitReached
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "起草服务还没上线，请稍后再试"
        case .proRequired(let message): message
        case .limitReached: "今天起草得太多了，明天再来"
        case .server(let message): message
        }
    }
}

/// Snuffle's own backend (a Cloudflare Worker at snuffle.ai/api). There is no account: each install has a random
/// id kept in this device's Keychain, and the server trusts it only together with a verified App Store purchase.
@MainActor
final class CloudClient {
    let baseURL: URL?
    private let http: HTTPClient

    init(baseURL: URL?, session: URLSession = .shared) {
        self.baseURL = baseURL?.host() == nil ? nil : baseURL
        http = HTTPClient(session: session)
    }

    convenience init(bundle: Bundle = .main) {
        self.init(baseURL: (bundle.object(forInfoDictionaryKey: "SnuffleAPIURL") as? String).flatMap(URL.init(string:)))
    }

    func draftReply(review: Review, appName: String, tone: AppSettings.ReplyTone, signature: String, proof: String?) async throws -> ReplyDraft {
        guard let baseURL else { throw CloudError.notConfigured }
        struct Body: Encodable {
            struct ReviewBody: Encodable {
                let platform: String
                let rating: Int
                let title: String?
                let body: String
                let author: String?
                let territory: String?
                let language: String?
            }
            let requestId: String
            let installId: String
            let appName: String
            let tone: String
            let signature: String
            let entitlement: String?
            let review: ReviewBody
        }
        let body = Body(
            requestId: UUID().uuidString,
            installId: InstallID.current,
            appName: appName,
            tone: tone.rawValue,
            signature: signature,
            entitlement: proof,
            review: .init(platform: review.platform.rawValue, rating: review.rating, title: review.title, body: review.body, author: review.author, territory: review.territory, language: review.language)
        )
        var request = URLRequest(url: baseURL.appending(path: "api/v1/draft-reply"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        do {
            return try await http.decode(ReplyDraft.self, request, platform: .posthog)
        } catch SourceError.http(_, 402, let message), SourceError.forbidden(_, let message) {
            throw CloudError.proRequired(message.isEmpty ? "起草回复是 Pro 功能" : message)
        } catch SourceError.rateLimited {
            throw CloudError.limitReached
        } catch let error as SourceError {
            throw CloudError.server(Self.reword(error))
        }
    }

    private static func reword(_ error: SourceError) -> String {
        switch error {
        case .network: "连不上 Snuffle 服务器，请检查网络"
        case .http(_, let code, let detail): "起草失败（\(code)）：\(detail)"
        default: "起草失败，请稍后再试"
        }
    }
}

/// A random id for this install, created on first use and kept in this device's Keychain.
enum InstallID {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "ai.snuffle.cloud",
        kSecAttrAccount as String: "install-id"
    ]

    static var current: String {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var item: CFTypeRef?
        if SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let id = String(data: data, encoding: .utf8), UUID(uuidString: id) != nil {
            return id
        }
        let id = UUID().uuidString.lowercased()
        var add = query
        add[kSecValueData as String] = Data(id.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
        return id
    }
}
