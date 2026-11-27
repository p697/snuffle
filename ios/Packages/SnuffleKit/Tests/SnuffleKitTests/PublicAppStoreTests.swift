import Foundation
import Testing
@testable import SnuffleKit

@Suite("App Store without a key")
struct PublicAppStoreTests {
    @Test func parsesSearchResultsThatAreApps() throws {
        let json = """
        {"resultCount":3,"results":[
          {"wrapperType":"software","kind":"software","trackId":1234567890,"trackName":"Lumen: 笔记与清单","bundleId":"com.example.lumen","artistName":"Example Labs, Inc.","artworkUrl100":"https://example.com/100x100bb.jpg","averageUserRating":4.70512,"userRatingCount":2140},
          {"wrapperType":"software","kind":"software","trackId":6837571701,"trackName":"Fresh","bundleId":"ai.example.fresh","averageUserRating":0,"userRatingCount":0},
          {"wrapperType":"artist","artistId":5,"artistName":"Someone"}
        ]}
        """
        let apps = try PublicAppStoreParsing.apps(Data(json.utf8))
        #expect(apps.map(\.id) == ["1234567890", "6837571701"])
        #expect(apps[0].developer == "Example Labs, Inc.")
        #expect(apps[0].rating == 4.70512 && apps[0].ratingCount == 2140)
        #expect(apps[0].icon?.absoluteString == "https://example.com/100x100bb.jpg")
        #expect(apps[1].rating == nil, "an app nobody rated has no rating, not 0")
    }

    @Test func parsesTheReviewsFeedInEveryShape() throws {
        let project = UUID()
        let many = """
        {"feed":{"entry":[
          {"author":{"name":{"label":"kat"}},"updated":{"label":"2026-11-25T17:50:13-07:00"},"im:rating":{"label":"1"},"im:version":{"label":"2.4"},"id":{"label":"4100000002"},"title":{"label":"Sucks"},"content":{"label":"Crashes on launch","attributes":{"type":"text"}}},
          {"author":{"name":{"label":"sam"}},"updated":{"label":"2026-11-24T08:00:00-07:00"},"im:rating":{"label":"5"},"id":{"label":"4100000001"},"title":{"label":"Great"},"content":{"label":"Love it"}}
        ]}}
        """
        let reviews = try PublicAppStoreParsing.reviews(Data(many.utf8), country: "ua", projectId: project)
        #expect(reviews.count == 2)
        #expect(reviews[0].storeId == "4100000002" && reviews[0].rating == 1 && reviews[0].body == "Crashes on launch")
        #expect(reviews[0].territory == "UKR", "stored as App Store Connect writes territories")
        #expect(reviews[0].appVersion == "2.4" && reviews[0].author == "kat")
        #expect(reviews[0].createdAt == ISO8601.parse("2026-11-26T00:50:13Z"))
        #expect(reviews.allSatisfy { $0.keyless == true && !$0.canReply && !$0.needsReply }, "without a key nobody knows what was answered")

        let one = #"{"feed":{"entry":{"author":{"name":{"label":"jo"}},"updated":{"label":"2026-11-24T08:00:00Z"},"im:rating":{"label":"4"},"id":{"label":"7"},"title":{"label":"Ok"},"content":{"label":"Fine"}}}}"#
        #expect(try PublicAppStoreParsing.reviews(Data(one.utf8), country: "us", projectId: project).map(\.storeId) == ["7"])
        let none = #"{"feed":{"author":{"name":{"label":"iTunes Store"}},"title":{"label":"iTunes Store: Customer Reviews"}}}"#
        #expect(try PublicAppStoreParsing.reviews(Data(none.utf8), country: "us", projectId: project).isEmpty)
        #expect(throws: SourceError.self) { try PublicAppStoreParsing.reviews(Data("<html>".utf8), country: "us", projectId: project) }
    }

    @Test func findsTheAppIdInALinkOrOnItsOwn() {
        #expect(PublicAppStoreClient.appId(in: "https://apps.apple.com/cn/app/lumen/id1234567890?l=en") == "1234567890")
        #expect(PublicAppStoreClient.appId(in: " 1234567890 ") == "1234567890")
        #expect(PublicAppStoreClient.appId(in: "Lumen") == nil)
        #expect(PublicAppStoreClient.appId(in: "2048") == nil, "a short number is a name to search for")
        #expect(PublicAppStoreClient.reviewsFeed(appId: "123456", country: "us")?.absoluteString == "https://itunes.apple.com/us/rss/customerreviews/page=1/id=123456/sortby=mostrecent/json")
        #expect(PublicAppStoreClient.reviewsFeed(appId: "12/34", country: "us") == nil)
    }

    @Test func weighsEachStorefrontByItsRatings() {
        let apps = [
            PublicApp(id: "1", name: "A", bundleId: "a", rating: 5, ratingCount: 30),
            PublicApp(id: "1", name: "A", bundleId: "a", rating: 3, ratingCount: 10),
            PublicApp(id: "1", name: "A", bundleId: "a", rating: nil, ratingCount: 0)
        ]
        #expect(PublicAppStoreClient.average(apps) == 4.5)
        #expect(PublicAppStoreClient.average([apps[2]]) == nil)
        #expect(Format.rating(4.5, locale: Locale(identifier: "de_DE")) == "4,5")
        #expect(Metric.rating.format(4.71) == Format.rating(4.71))
    }

    @Test func looksInThePhonesStorefrontFirst() {
        #expect(PublicAppStoreClient.candidates(region: "UA").prefix(3) == ["ua", "us", "cn"])
        #expect(PublicAppStoreClient.candidates(region: "US").filter { $0 == "us" }.count == 1)
        #expect(PublicAppStoreClient.candidates(region: "AQ").first == "us", "a region without a storefront is skipped")
        #expect(Territory.alpha3(fromAlpha2: "gb") == "GBR")
        #expect(Territory.storefronts.contains("cn") && Territory.storefronts.allSatisfy { $0 == $0.lowercased() })
    }

    @Test func linksFromBeforeKeylessReadingStillDecode() throws {
        let account = UUID()
        let old = #"{"accountId":"\#(account.uuidString)","appId":"1","appName":"Lumen","bundleId":"com.example.lumen"}"#
        let link = try JSONDecoder().decode(AppStoreLink.self, from: Data(old.utf8))
        #expect(link.accountId == account && link.hasKey && link.countries.isEmpty)
        let keyless = AppStoreLink(accountId: nil, appId: "1", appName: "Lumen", bundleId: "b", countries: ["us", "cn", "jp", "gb", "de", "fr"])
        #expect(keyless.countries.count == AppStoreLink.maxCountries)
        let again = try JSONDecoder().decode(AppStoreLink.self, from: JSONEncoder().encode(keyless))
        #expect(again == keyless && !again.hasKey)
    }

    @Test func aKeylessAppStoreShowsItsRatingNotRepliesToWrite() {
        var project = Project(name: "Lumen", tint: .ink, appStore: AppStoreLink(accountId: nil, appId: "1", appName: "Lumen", bundleId: "b", countries: ["us"]))
        #expect(!project.answersReviews && project.hasStore)
        #expect(!Metric.reviewsToAnswer.isAvailable(in: project))
        #expect(Metric.rating.isAvailable(in: project))
        #expect(CardLayout.standard(for: project).big == [.rating])

        project.appStore?.countries = []
        #expect(!Metric.rating.isAvailable(in: project), "an app on no storefront yet has no rating")
        #expect(CardLayout.standard(for: project).big == [.revenue])

        project.appStore?.accountId = UUID()
        #expect(project.answersReviews && Metric.reviewsToAnswer.platforms(in: project) == [.appStore])
        #expect(CardLayout.standard(for: project).big == [.reviewsToAnswer])
    }
}

extension LiveProviderTests {
    @Test func readsTheAppStoreWithoutAKey() async throws {
        let feed = #"{"feed":{"entry":[{"author":{"name":{"label":"kat"}},"updated":{"label":"2026-11-19T17:50:13-07:00"},"im:rating":{"label":"2"},"id":{"label":"901"},"title":{"label":"Meh"},"content":{"label":"Slow"}}]}}"#
        StubProtocol.reset([
            "itunes.apple.com/us/rss/customerreviews": (200, feed),
            "itunes.apple.com/jp/rss/customerreviews": (200, #"{"feed":{}}"#),
            "itunes.apple.com/lookup": (200, #"{"results":[{"wrapperType":"software","trackId":1,"trackName":"Lumen","bundleId":"b","averageUserRating":4.2,"userRatingCount":12}]}"#)
        ])
        let project = Project(name: "Lumen", tint: .ink, appStore: AppStoreLink(accountId: nil, appId: "1", appName: "Lumen", bundleId: "b", countries: ["us", "jp"]))
        let result = await provider(store: MemoryCredentialStore([:])).refresh(project, metrics: [.rating, .reviewsToAnswer], previous: nil)
        #expect(result.snapshot.failures.isEmpty)
        #expect(result.snapshot[.rating] == 4.2)
        #expect(result.reviews[.appStore]?.map(\.storeId) == ["901"])
        #expect(result.reviews[.appStore]?.first?.territory == "USA")
        #expect(!StubProtocol.seen.contains { $0.url?.host() == "api.appstoreconnect.apple.com" })

        // A refused feed is Apple holding requests back: the source fails quietly, with nothing to sign in to.
        StubProtocol.reset(["itunes.apple.com/": (403, "Forbidden")])
        let refused = await provider(store: MemoryCredentialStore([:])).refresh(project, metrics: [], previous: nil)
        #expect(refused.snapshot.failures.map(\.kind) == [.rateLimited])
        #expect(refused.reviews[.appStore] == nil, "the reviews kept from the last read stay")
        await #expect(throws: SourceError.missingCredential(.appStore)) {
            try await provider(store: MemoryCredentialStore([:])).reply(to: result.reviews[.appStore]![0], text: "Thanks", in: project)
        }
    }
}
