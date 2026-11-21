import SnuffleKit
import XCTest
@testable import Snuffle

/// What the app sends to snuffle.ai/api and how it reads the answers, against a stubbed network.
@MainActor
final class CloudClientTests: XCTestCase {
    private let review = Review(
        storeId: "1", platform: .appStore, projectId: UUID(), rating: 2, title: "Crash",
        body: "Crashes when I attach a PDF", author: "Mia", territory: "US", language: "en", createdAt: Date()
    )

    override func tearDown() {
        CloudStub.handler = nil
        super.tearDown()
    }

    private func client(_ base: String = "https://snuffle.test") -> CloudClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudStub.self]
        return CloudClient(baseURL: URL(string: base), session: URLSession(configuration: configuration))
    }

    private func draft(_ client: CloudClient) async throws -> ReplyDraft {
        try await client.draftReply(review: review, appName: "Lumen Notes", tone: .warm, signature: "Mia", proof: "signed-jws")
    }

    private func failure(of client: CloudClient) async -> CloudError? {
        do {
            _ = try await draft(client)
            XCTFail("expected an error")
            return nil
        } catch {
            return error as? CloudError
        }
    }

    func testSendsTheReviewWithAStableInstallId() async throws {
        var bodies: [[String: Any]] = []
        CloudStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://snuffle.test/api/v1/draft-reply")
            bodies.append(try JSONSerialization.jsonObject(with: CloudStub.body(of: request)) as! [String: Any])
            return (200, #"{"reply":"Sorry about that!","translation":"抱歉！","language":"en"}"#)
        }
        let client = client()
        let first = try await draft(client)
        _ = try await draft(client)

        XCTAssertEqual(first, ReplyDraft(reply: "Sorry about that!", translation: "抱歉！", language: "en"))
        XCTAssertEqual(bodies.count, 2)
        let installId = try XCTUnwrap(bodies[0]["installId"] as? String)
        XCTAssertNotNil(UUID(uuidString: installId))
        XCTAssertEqual(bodies[1]["installId"] as? String, installId, "one id per install, kept in the Keychain")
        XCTAssertNotEqual(bodies[0]["requestId"] as? String, bodies[1]["requestId"] as? String)
        XCTAssertEqual(bodies[0]["entitlement"] as? String, "signed-jws")
        let sent = try XCTUnwrap(bodies[0]["review"] as? [String: Any])
        XCTAssertEqual(sent["platform"] as? String, "appStore")
        XCTAssertEqual(sent["rating"] as? Int, 2)
    }

    func testRefusalsBecomeTheirOwnErrors() async throws {
        let client = client()
        CloudStub.handler = { _ in (402, #"{"code":"pro_required","message":"这笔购买已经在太多设备上使用"}"#) }
        let shared = await failure(of: client)
        XCTAssertEqual(shared, .proRequired("这笔购买已经在太多设备上使用"))
        CloudStub.handler = { _ in (429, #"{"code":"limit","message":"今天起草得太多了，明天再来"}"#) }
        let limited = await failure(of: client)
        XCTAssertEqual(limited, .limitReached)
        CloudStub.handler = { _ in (503, #"{"code":"unavailable","message":"起草服务暂时不可用"}"#) }
        let unavailable = await failure(of: client)
        XCTAssertEqual(unavailable, .server("起草失败（503）：起草服务暂时不可用"))
    }

    func testAMissingAddressIsNotConfigured() async {
        let unconfigured = await failure(of: client("not a url"))
        XCTAssertEqual(unconfigured, .notConfigured)
    }

    /// Talks to a deployed server when SNUFFLE_LIVE_API_URL is set. Local StoreKit proofs must be refused there.
    func testLiveServerRefusesALocalTestPurchase() async throws {
        guard let base = ProcessInfo.processInfo.environment["SNUFFLE_LIVE_API_URL"].flatMap(URL.init(string:)) else {
            throw XCTSkip("set SNUFFLE_LIVE_API_URL to run")
        }
        let client = CloudClient(baseURL: base)
        let live = await failure(of: client)
        XCTAssertEqual(live, .proRequired("没有有效的 Pro 订阅"))
    }
}

/// Answers every request with whatever the current test says.
final class CloudStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, String))?

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (status, body) = try XCTUnwrap(Self.handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
