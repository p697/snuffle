import Foundation

/// A signed-in account or imported key on one platform. Secrets live in the Keychain under the account's id, never here.
public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var platform: Platform
    /// What the person recognises: an email, a team name, a key name.
    public var title: String
    /// One line of context, e.g. "美国区" or "密钥 S59L…".
    public var subtitle: String
    public var createdAt: Date

    public init(id: UUID = UUID(), platform: Platform, title: String, subtitle: String, createdAt: Date = .now) {
        self.id = id
        self.platform = platform
        self.title = title
        self.subtitle = subtitle
        self.createdAt = createdAt
    }
}

/// The secret part of an account.
public enum Credential: Codable, Sendable, Equatable {
    case posthogOAuth(PostHogOAuthToken)
    case posthogPersonalKey(host: String, key: String)
    case revenueCat(secretKey: String)
    case appStoreConnect(issuerId: String, keyId: String, privateKeyPEM: String)
    case googleOAuth(GoogleOAuthToken)

    public var platform: Platform {
        switch self {
        case .posthogOAuth, .posthogPersonalKey: .posthog
        case .revenueCat: .revenueCat
        case .appStoreConnect: .appStore
        case .googleOAuth: .googlePlay
        }
    }
}

public struct PostHogOAuthToken: Codable, Sendable, Equatable {
    /// "https://us.posthog.com" or "https://eu.posthog.com".
    public var host: String
    public var clientId: String
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?

    public init(host: String, clientId: String, accessToken: String, refreshToken: String?, expiresAt: Date?) {
        self.host = host
        self.clientId = clientId
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public struct GoogleOAuthToken: Codable, Sendable, Equatable {
    public var clientId: String
    public var accessToken: String?
    public var refreshToken: String
    public var expiresAt: Date?

    public init(clientId: String, accessToken: String?, refreshToken: String, expiresAt: Date?) {
        self.clientId = clientId
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}
