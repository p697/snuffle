import CryptoKit
import Foundation

/// PKCE values for one authorization attempt (RFC 7636).
public struct PKCE: Sendable, Equatable {
    public var verifier: String
    public var challenge: String
    public var state: String

    public init() {
        self.init(verifier: PKCE.random(48), state: PKCE.random(24))
    }

    public init(verifier: String, state: String) {
        self.verifier = verifier
        challenge = AppStoreConnectToken.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        self.state = state
    }

    static func random(_ count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return AppStoreConnectToken.base64URL(Data(bytes))
    }
}

/// Authorization code flow against PostHog. The client is described by a metadata document on snuffle.ai, so PostHog
/// registers it on first use with no secret involved.
public enum PostHogOAuth {
    public static let clientId = "https://snuffle.ai/oauth/posthog-client.json"
    /// An https redirect on the client document's domain. It returns to the app through the webcredentials association
    /// in snuffle.ai/.well-known/apple-app-site-association, which PostHog's app verification asks for.
    public static let callbackHost = "snuffle.ai"
    public static let callbackPath = "/oauth/posthog"
    public static let redirectURI = "https://\(callbackHost)\(callbackPath)"
    public static let scopes = ["user:read", "organization:read", "project:read", "query:read", "dashboard:read", "insight:read"]

    public enum Region: String, CaseIterable, Sendable, Identifiable {
        case us, eu
        public var id: String { rawValue }
        public var host: URL { URL(string: rawValue == "us" ? "https://us.posthog.com" : "https://eu.posthog.com")! }
        public var label: String { rawValue == "us" ? String(localized: "美国区", bundle: .module) : String(localized: "欧洲区", bundle: .module) }
    }

    public static func authorizeURL(region: Region, pkce: PKCE) -> URL {
        region.host.appending(path: "oauth/authorize/").appendingQuery([
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state)
        ])
    }

    /// Reads the authorization code from the redirect, rejecting a mismatched state.
    public static func code(from callback: URL, pkce: PKCE) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw SourceError.forbidden(.posthog, error == "access_denied" ? String(localized: "你取消了授权", bundle: .module) : error)
        }
        guard items.first(where: { $0.name == "state" })?.value == pkce.state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw SourceError.invalidResponse(.posthog, "callback without code")
        }
        return code
    }

    public static func exchange(code: String, pkce: PKCE, region: Region, http: HTTPClient = HTTPClient()) async throws -> PostHogOAuthToken {
        try await token(host: region.host, form: [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientId,
            "redirect_uri": redirectURI,
            "code_verifier": pkce.verifier
        ], refreshFallback: nil, http: http)
    }

    public static func refresh(_ current: PostHogOAuthToken, http: HTTPClient = HTTPClient()) async throws -> PostHogOAuthToken {
        guard let refreshToken = current.refreshToken else { throw SourceError.unauthorized(.posthog) }
        return try await token(host: URL(string: current.host)!, form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": current.clientId
        ], refreshFallback: refreshToken, http: http)
    }

    private static func token(host: URL, form: [String: String], refreshFallback: String?, http: HTTPClient) async throws -> PostHogOAuthToken {
        struct Response: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
        }
        var request = URLRequest(url: host.appending(path: "oauth/token/"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormBody.encode(form)
        let response: Response = try await http.decode(Response.self, request, platform: .posthog)
        return PostHogOAuthToken(
            host: host.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            clientId: form["client_id"] ?? clientId,
            accessToken: response.access_token,
            refreshToken: response.refresh_token ?? refreshFallback,
            expiresAt: response.expires_in.map { Date().addingTimeInterval($0 - 60) }
        )
    }
}

/// Google sign-in for the Play Developer API with an iOS OAuth client (public, no secret).
public enum GoogleOAuth {
    public static let scope = "https://www.googleapis.com/auth/androidpublisher"
    /// Read-only Play Console reporting; Snuffle uses it only to list the apps the account can open.
    public static let appsScope = "https://www.googleapis.com/auth/playdeveloperreporting"

    /// The redirect Google expects for an iOS client: the reversed client id as a scheme.
    public static func callbackScheme(clientId: String) -> String {
        clientId.split(separator: ".").reversed().joined(separator: ".")
    }

    public static func redirectURI(clientId: String) -> String {
        callbackScheme(clientId: clientId) + ":/oauth/google"
    }

    public static func authorizeURL(clientId: String, pkce: PKCE) -> URL {
        URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!.appendingQuery([
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI(clientId: clientId)),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email \(scope) \(appsScope)"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ])
    }

    public static func code(from callback: URL, pkce: PKCE) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw SourceError.forbidden(.googlePlay, error == "access_denied" ? String(localized: "你取消了授权", bundle: .module) : error)
        }
        guard items.first(where: { $0.name == "state" })?.value == pkce.state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw SourceError.invalidResponse(.googlePlay, "callback without code")
        }
        return code
    }

    /// Exchanges the code; also returns the signed-in email from the ID token for the account's title.
    public static func exchange(code: String, pkce: PKCE, clientId: String, http: HTTPClient = HTTPClient()) async throws -> (GoogleOAuthToken, email: String?) {
        let response = try await token(form: [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientId,
            "redirect_uri": redirectURI(clientId: clientId),
            "code_verifier": pkce.verifier
        ], http: http)
        guard let refresh = response.refresh_token else {
            throw SourceError.invalidResponse(.googlePlay, String(localized: "Google 没有返回长期授权，请重试", bundle: .module))
        }
        let token = GoogleOAuthToken(clientId: clientId, accessToken: response.access_token, refreshToken: refresh, expiresAt: Date().addingTimeInterval(response.expires_in - 60))
        return (token, response.id_token.flatMap(email(fromIDToken:)))
    }

    public static func refresh(_ current: GoogleOAuthToken, http: HTTPClient = HTTPClient()) async throws -> GoogleOAuthToken {
        let response = try await token(form: [
            "grant_type": "refresh_token",
            "refresh_token": current.refreshToken,
            "client_id": current.clientId
        ], http: http)
        return GoogleOAuthToken(clientId: current.clientId, accessToken: response.access_token, refreshToken: response.refresh_token ?? current.refreshToken, expiresAt: Date().addingTimeInterval(response.expires_in - 60))
    }

    struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
        let id_token: String?
    }

    private static func token(form: [String: String], http: HTTPClient) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormBody.encode(form)
        return try await http.decode(TokenResponse.self, request, platform: .googlePlay)
    }

    /// The ID token arrived directly from Google over TLS, so its payload is read without verifying the signature.
    static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["email"] as? String
    }
}

enum FormBody {
    static func encode(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}
