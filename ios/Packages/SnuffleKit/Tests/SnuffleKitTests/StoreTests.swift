import CryptoKit
import Foundation
import Testing
@testable import SnuffleKit

@Suite("Stores and keys")
struct StoreTests {
    @Test func appStoreTokenIsAValidES256JWT() throws {
        let key = P256.Signing.PrivateKey()
        let token = try AppStoreConnectToken(issuerId: " 57246542-96fe-1a63-e053-0824d011072a ", keyId: "ABC123DEFG", privateKeyPEM: key.pemRepresentation)
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let jwt = try token.make(now: now)
        let parts = jwt.split(separator: ".").map(String.init)
        #expect(parts.count == 3)

        func decode(_ part: String) throws -> [String: Any] {
            var text = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while text.count % 4 != 0 { text += "=" }
            let data = try #require(Data(base64Encoded: text))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let header = try decode(parts[0])
        let payload = try decode(parts[1])
        #expect(header["alg"] as? String == "ES256")
        #expect(header["kid"] as? String == "ABC123DEFG")
        #expect(payload["iss"] as? String == "57246542-96fe-1a63-e053-0824d011072a")
        #expect(payload["aud"] as? String == "appstoreconnect-v1")
        #expect(payload["exp"] as? Int == 1_795_000_900)

        var signature = parts[2].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while signature.count % 4 != 0 { signature += "=" }
        let raw = try #require(Data(base64Encoded: signature))
        let ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        #expect(key.publicKey.isValidSignature(ecdsa, for: Data((parts[0] + "." + parts[1]).utf8)))
    }

    @Test func individualKeyTokenHasNoIssuer() throws {
        let key = P256.Signing.PrivateKey()
        let token = try AppStoreConnectToken(issuerId: "", keyId: "XYZ987WVUT", privateKeyPEM: key.pemRepresentation)
        #expect(token.isIndividual)
        let payloadPart = try token.make(now: Date(timeIntervalSince1970: 1_795_000_000)).split(separator: ".")[1]
        var text = payloadPart.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        let data = try #require(Data(base64Encoded: text))
        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["sub"] as? String == "user")
        #expect(payload["iss"] == nil)
        #expect(payload["aud"] as? String == "appstoreconnect-v1")
    }

    @Test func rejectsTextThatIsNotAKey() {
        #expect(throws: SourceError.self) {
            _ = try AppStoreConnectToken(issuerId: "i", keyId: "k", privateKeyPEM: "-----BEGIN PRIVATE KEY-----\nnope\n-----END PRIVATE KEY-----")
        }
    }

    @Test func parsesAppStoreReviewsWithReplies() throws {
        let json = """
        {"data":[
          {"type":"customerReviews","id":"r1","attributes":{"rating":1,"title":"Broken","body":"Crashes","reviewerNickname":"kat","createdDate":"2026-11-20T08:00:00-07:00","territory":"UKR"},
           "relationships":{"response":{"data":{"type":"customerReviewResponses","id":"p1"}}}},
          {"type":"customerReviews","id":"r2","attributes":{"rating":5,"title":"Love it","body":"Great","reviewerNickname":"sam","createdDate":"2026-11-19T08:00:00Z","territory":"USA"},
           "relationships":{"response":{"data":null}}}
        ],
        "included":[{"type":"customerReviewResponses","id":"p1","attributes":{"responseBody":"Fixed in 2.1","lastModifiedDate":"2026-11-20T10:00:00Z","state":"PENDING_PUBLISH"}}]}
        """
        let project = UUID()
        let reviews = try AppStoreParsing.reviews(Data(json.utf8), projectId: project)
        #expect(reviews.count == 2)
        #expect(reviews[0].reply?.text == "Fixed in 2.1")
        #expect(reviews[0].reply?.pending == true)
        #expect(reviews[0].territory == "UKR")
        #expect(reviews[0].createdAt == ISO8601.parse("2026-11-20T15:00:00Z"))
        #expect(reviews[1].needsReply)
        #expect(reviews[1].id == "appStore:r2")
    }

    @Test func parsesPlayReviews() throws {
        let json = """
        {"reviews":[
          {"reviewId":"g1","authorName":"Olena","comments":[{"userComment":{"text":"\\tДякую!","lastModified":{"seconds":"1795100000"},"starRating":5,"reviewerLanguage":"uk_UA"}}]},
          {"reviewId":"g2","authorName":"Jo","comments":[{"userComment":{"text":"Meh","lastModified":{"seconds":"1795000000"},"starRating":2,"appVersionName":"2.1.0","androidOsVersion":34,"thumbsUpCount":7,"device":"dm3q","deviceMetadata":{"manufacturer":"samsung","productName":"Galaxy S23 Ultra"}}},{"developerComment":{"text":"Sorry!","lastModified":{"seconds":"1795050000"}}}]}
        ],"tokenPagination":{"nextPageToken":"next"}}
        """
        let page = try GooglePlayParsing.reviews(Data(json.utf8), projectId: UUID())
        #expect(page.nextPageToken == "next")
        #expect(page.reviews[0].body == "Дякую!")
        #expect(page.reviews[0].language == "uk_UA")
        #expect(page.reviews[0].needsReply)
        #expect(page.reviews[1].reply?.text == "Sorry!")
        #expect(page.reviews[1].createdAt == Date(timeIntervalSince1970: 1_795_000_000))
        #expect(page.reviews[1].appVersion == "2.1.0")
        #expect(page.reviews[1].device == "Samsung Galaxy S23 Ultra")
        #expect(page.reviews[1].system == "Android 14")
        #expect(page.reviews[1].helpful == 7)
        #expect(page.reviews[0].appVersion == nil && page.reviews[0].device == nil && page.reviews[0].helpful == nil)
        #expect(GooglePlayParsing.device(maker: "Google", model: "Pixel 8") == "Google Pixel 8")
        #expect(GooglePlayParsing.device(maker: "Google", model: "google Pixel 8") == "google Pixel 8", "the maker is not named twice")
        #expect(GooglePlayParsing.device(maker: "Xiaomi", model: nil) == "Xiaomi")
        #expect(GooglePlayParsing.android(32) == "Android 12L" && GooglePlayParsing.android(40) == "API 40")
    }

    @Test func parsesOnePlayReviewByItsId() throws {
        let json = #"{"reviewId":"1a2b","authorName":"Nick","comments":[{"userComment":{"text":"Great","lastModified":{"seconds":"1794089798"},"starRating":5,"appVersionName":"1.0.0"}},{"developerComment":{"text":"Thanks!","lastModified":{"seconds":"1794100000"}}}]}"#
        let review = try #require(try GooglePlayParsing.review(Data(json.utf8), projectId: UUID()))
        #expect(review.storeId == "1a2b" && review.rating == 5 && review.appVersion == "1.0.0")
        #expect(review.reply?.text == "Thanks!")
        #expect(try GooglePlayParsing.review(Data(#"{"reviewId":"x","comments":[]}"#.utf8), projectId: UUID()) == nil)
    }

    @Test func readsTheLatestDayOfPlayVitals() throws {
        let set = #"{"name":"apps/com.example.atlas/crashRateMetricSet","freshnessInfo":{"freshnesses":[{"aggregationPeriod":"HOURLY","latestEndTime":{"year":2026,"month":11,"day":25,"hours":7,"timeZone":{"id":"UTC"}}},{"aggregationPeriod":"DAILY","latestEndTime":{"year":2026,"month":12,"day":1,"timeZone":{"id":"America/Los_Angeles"}}}]}}"#
        let end = try #require(try GooglePlayParsing.latestDay(Data(set.utf8)))
        #expect(end == GooglePlayParsing.Day(year: 2026, month: 12, day: 1))
        #expect(end.dayBefore == GooglePlayParsing.Day(year: 2026, month: 11, day: 30), "across the month")
        #expect(try GooglePlayParsing.latestDay(Data(#"{"name":"x"}"#.utf8)) == nil, "no data yet")

        let rows = #"{"rows":[{"aggregationPeriod":"DAILY","startTime":{"year":2026,"month":11,"day":30,"timeZone":{"id":"America/Los_Angeles"}},"metrics":[{"metric":"userPerceivedCrashRate28dUserWeighted","decimalValue":{"value":"0.0127"}}]}]}"#
        #expect(try GooglePlayParsing.rate(Data(rows.utf8), metric: "userPerceivedCrashRate28dUserWeighted") == 0.0127)
        #expect(try GooglePlayParsing.rate(Data("{}".utf8), metric: "userPerceivedCrashRate28dUserWeighted") == nil, "too few people")
    }

    @Test func mapsRevenueCatOverview() {
        let overview = RevenueCatClient.overview(from: [("mrr", 87), ("active_subscriptions", 47), ("active_trials", 3), ("revenue", 96.4), ("other", 1)])
        #expect(overview == SubscriptionOverview(mrr: 87, activeSubscriptions: 47, activeTrials: 3, revenueLast28Days: 96.4))
        #expect(RevenueCatClient.utcDate(ISO8601.parse("2026-11-20T23:30:00-05:00")!) == "2026-11-21")
    }

    @Test func readsEmailFromGoogleIDToken() {
        let payload = AppStoreConnectToken.base64URL(Data(#"{"email":"dev@example.com","sub":"1"}"#.utf8))
        #expect(GoogleOAuth.email(fromIDToken: "h.\(payload).s") == "dev@example.com")
        #expect(GoogleOAuth.callbackScheme(clientId: "123-abc.apps.googleusercontent.com") == "com.googleusercontent.apps.123-abc")
    }

    @Test func encodesFormBodies() {
        let body = String(decoding: FormBody.encode(["b": "a b&c", "a": "x/y"]), as: UTF8.self)
        #expect(body == "a=x%2Fy&b=a%20b%26c")
    }

    @Test func fileStoreRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = FileStore<AppSettings>(directory: directory, name: "settings.json")
        #expect(store.load() == nil)
        var settings = AppSettings()
        settings.sound = true
        store.save(settings)
        #expect(store.load() == settings)
        store.remove()
        #expect(store.load() == nil)
    }

    @Test func errorBodiesBecomeShortMessages() {
        #expect(HTTPClient.detail(from: Data(#"{"detail":"Permission denied"}"#.utf8)) == "Permission denied")
        #expect(HTTPClient.detail(from: Data(#"{"errors":[{"title":"Forbidden","detail":"Key lacks role"}]}"#.utf8)) == "Key lacks role")
        #expect(HTTPClient.detail(from: Data(#"{"error":{"message":"bad key"}}"#.utf8)) == "bad key")
        #expect(HTTPClient.detail(from: Data()) == String(localized: "没有说明", bundle: .module))
    }
}
