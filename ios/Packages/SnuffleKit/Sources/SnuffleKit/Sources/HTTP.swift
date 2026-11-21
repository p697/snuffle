import Foundation

/// Why a source could not be read, worded for the person looking at the card.
public enum SourceError: Error, Equatable, Sendable, LocalizedError {
    case missingCredential(Platform)
    case unauthorized(Platform)
    case forbidden(Platform, String)
    case rateLimited(Platform)
    case http(Platform, Int, String)
    case network(Platform, String)
    case invalidResponse(Platform, String)
    case invalidKey(String)

    public var platform: Platform? {
        switch self {
        case .missingCredential(let p), .unauthorized(let p), .forbidden(let p, _), .rateLimited(let p),
             .http(let p, _, _), .network(let p, _), .invalidResponse(let p, _):
            p
        case .invalidKey:
            nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missingCredential(let p): String(localized: "\(p.displayName) 还没有登录", bundle: .module)
        case .unauthorized(let p): String(localized: "\(p.displayName) 的登录已失效，请重新连接", bundle: .module)
        case .forbidden(let p, let detail): String(localized: "\(p.displayName) 拒绝了请求：\(detail)", bundle: .module)
        case .rateLimited(let p): String(localized: "\(p.displayName) 请求太频繁，稍后再试", bundle: .module)
        case .http(let p, let code, let detail): String(localized: "\(p.displayName) 返回 \(String(code))：\(detail)", bundle: .module)
        case .network(let p, let detail): String(localized: "连不上 \(p.displayName)：\(detail)", bundle: .module)
        case .invalidResponse(let p, let detail): String(localized: "\(p.displayName) 返回了看不懂的数据：\(detail)", bundle: .module)
        case .invalidKey(let detail): detail
        }
    }
}

/// A small JSON transport shared by every platform client.
public struct HTTPClient: Sendable {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest, platform: Platform) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SourceError.network(platform, error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.invalidResponse(platform, "no HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw SourceError.unauthorized(platform)
        case 403:
            throw SourceError.forbidden(platform, Self.detail(from: data))
        case 429:
            throw SourceError.rateLimited(platform)
        default:
            throw SourceError.http(platform, http.statusCode, Self.detail(from: data))
        }
    }

    public func decode<T: Decodable>(_ type: T.Type, _ request: URLRequest, platform: Platform) async throws -> T {
        let data = try await send(request, platform: platform)
        do {
            return try JSONDecoder.snuffle.decode(T.self, from: data)
        } catch {
            throw SourceError.invalidResponse(platform, String(describing: error).prefix(160).description)
        }
    }

    /// Pulls a short human message out of an error body, whatever shape the platform uses.
    static func detail(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["detail", "message", "error_description", "error"] {
                if let text = object[key] as? String, !text.isEmpty { return String(text.prefix(160)) }
                if let nested = object[key] as? [String: Any], let text = nested["message"] as? String { return String(text.prefix(160)) }
            }
            if let errors = object["errors"] as? [[String: Any]], let first = errors.first {
                let text = (first["detail"] as? String) ?? (first["title"] as? String) ?? ""
                if !text.isEmpty { return String(text.prefix(160)) }
            }
        }
        let text = String(decoding: data.prefix(160), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? String(localized: "没有说明", bundle: .module) : text
    }
}

extension JSONDecoder {
    static var snuffle: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = ISO8601.parse(text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised date \(text)")
        }
        return decoder
    }
}

/// ISO 8601 parsing that accepts the variants the four platforms send (with or without fractions, "Z" or an offset).
public enum ISO8601 {
    public static func parse(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? withFraction.parse(text) { return date }
        // PostHog sometimes returns "2026-11-20 09:30:00.123456" without a zone; it is UTC.
        let normalized = text.replacingOccurrences(of: " ", with: "T")
        if let date = try? withFraction.parse(normalized + "Z") { return date }
        if let date = try? Date(normalized + "Z", strategy: .iso8601) { return date }
        return nil
    }
}

/// A decoded JSON value, for query results whose columns vary.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var double: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        case .bool(let value): value ? 1 : 0
        default: nil
        }
    }

    public var int: Int? { double.map { Int($0.rounded()) } }

    public var string: String? {
        switch self {
        case .string(let value): value.isEmpty ? nil : value
        case .number(let value): value == value.rounded() ? String(Int(value)) : String(value)
        default: nil
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }
}

extension URL {
    func appendingQuery(_ items: [URLQueryItem]) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + items
        return components.url!
    }
}
