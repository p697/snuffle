import Foundation
import Testing
@testable import SnuffleKit

@Suite("Failure kinds")
struct FailureKindTests {
    @Test func sourceErrorsMapToKinds() {
        #expect(FailureKind(SourceError.unauthorized(.posthog)) == .unauthorized)
        #expect(FailureKind(SourceError.http(.revenueCat, 503, "down")) == .serverError)
        #expect(FailureKind(SourceError.http(.appStore, 404, "gone")) == .clientError)
        #expect(FailureKind(SourceError.network(.googlePlay, "offline")) == .network)
        #expect(FailureKind(CancellationError()) == .other)
    }

    @Test func cachesWithoutKindsStillDecode() throws {
        let json = Data(#"{"platform":"posthog","message":"PostHog 的登录已失效"}"#.utf8)
        let failure = try JSONDecoder().decode(SourceFailure.self, from: json)
        #expect(failure.kind == nil)
    }

    @Test func liveFailuresCarryTheKind() {
        let failure = LiveProvider.failure(.revenueCat, SourceError.rateLimited(.revenueCat))
        #expect(failure.kind == .rateLimited)
    }
}
