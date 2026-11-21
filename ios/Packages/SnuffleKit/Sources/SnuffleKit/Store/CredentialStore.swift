import Foundation
import Security

/// Where secrets live. The app and its widget extension share one Keychain access group.
public protocol CredentialStore: Sendable {
    func credential(for accountId: UUID) throws -> Credential?
    func save(_ credential: Credential, for accountId: UUID) throws
    func delete(accountId: UUID) throws
}

public struct KeychainCredentialStore: CredentialStore {
    public var service: String
    public var accessGroup: String?

    public init(service: String = "ai.snuffle.credentials", accessGroup: String?) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func query(_ accountId: UUID) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId.uuidString
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func credential(for accountId: UUID) throws -> Credential? {
        var query = query(accountId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(Credential.self, from: data)
    }

    public func save(_ credential: Credential, for accountId: UUID) throws {
        let data = try JSONEncoder().encode(credential)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query(accountId) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(accountId)
            add[kSecValueData as String] = data
            // Readable after first unlock so the widget can refresh in the background.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func delete(accountId: UUID) throws {
        let status = SecItemDelete(query(accountId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, LocalizedError {
    public var status: OSStatus
    public var errorDescription: String? { String(localized: "钥匙串读写失败（\(String(status))）", bundle: .module) }
}

/// In-memory store for tests and previews.
public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var items: [UUID: Credential] = [:]
    private let lock = NSLock()

    public init(_ items: [UUID: Credential] = [:]) {
        self.items = items
    }

    public func credential(for accountId: UUID) throws -> Credential? {
        lock.withLock { items[accountId] }
    }

    public func save(_ credential: Credential, for accountId: UUID) throws {
        lock.withLock { items[accountId] = credential }
    }

    public func delete(accountId: UUID) throws {
        lock.withLock { _ = items.removeValue(forKey: accountId) }
    }
}

/// Hands out fresh access tokens, refreshing and saving OAuth tokens when they expire. One refresh at a time per
/// account, so a refresh of three projects on one account never races to rotate the same refresh token.
public actor TokenBroker {
    private let store: any CredentialStore
    private let http: HTTPClient
    private var inFlight: [UUID: Task<Credential, Error>] = [:]

    public init(store: any CredentialStore, http: HTTPClient = HTTPClient()) {
        self.store = store
        self.http = http
    }

    public func credential(_ accountId: UUID, platform: Platform) throws -> Credential {
        guard let credential = try store.credential(for: accountId) else { throw SourceError.missingCredential(platform) }
        return credential
    }

    /// A bearer token for PostHog, refreshed when within a minute of expiry or when `force` is set after a 401.
    public func posthogToken(_ accountId: UUID, force: Bool = false) async throws -> (host: URL, token: String) {
        let credential = try await fresh(accountId, platform: .posthog, force: force)
        switch credential {
        case .posthogOAuth(let token): return (URL(string: token.host)!, token.accessToken)
        case .posthogPersonalKey(let host, let key): return (URL(string: host)!, key)
        default: throw SourceError.missingCredential(.posthog)
        }
    }

    public func googleToken(_ accountId: UUID, force: Bool = false) async throws -> String {
        let credential = try await fresh(accountId, platform: .googlePlay, force: force)
        guard case .googleOAuth(let token) = credential, let access = token.accessToken else { throw SourceError.missingCredential(.googlePlay) }
        return access
    }

    private func fresh(_ accountId: UUID, platform: Platform, force: Bool) async throws -> Credential {
        if let task = inFlight[accountId] { return try await task.value }
        let current = try credential(accountId, platform: platform)
        guard force || needsRefresh(current) else { return current }
        let http = self.http
        let store = self.store
        let task = Task<Credential, Error> {
            let renewed: Credential
            switch current {
            case .posthogOAuth(let token): renewed = .posthogOAuth(try await PostHogOAuth.refresh(token, http: http))
            case .googleOAuth(let token): renewed = .googleOAuth(try await GoogleOAuth.refresh(token, http: http))
            default: return current
            }
            try store.save(renewed, for: accountId)
            return renewed
        }
        inFlight[accountId] = task
        defer { inFlight[accountId] = nil }
        return try await task.value
    }

    private func needsRefresh(_ credential: Credential) -> Bool {
        switch credential {
        case .posthogOAuth(let token): token.expiresAt.map { $0 < Date() } ?? false
        case .googleOAuth(let token): token.accessToken == nil || (token.expiresAt.map { $0 < Date() } ?? true)
        default: false
        }
    }
}
