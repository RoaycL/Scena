import Foundation
import Testing
@testable import wallhaven

struct CloudflareHardeningTests {
    private let testDefaults = TestDefaults()

    @Test func pagesThatEmbedTurnstileAreNotChallenges() throws {
        let normal = Data("""
        <html><head><title>Live wallpapers</title>
        <script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script></head>
        <body>No results</body></html>
        """.utf8)
        #expect(!CloudflareChallengeDetector.isChallenge(normal))
        #expect(try WallsflowSource.parse(String(decoding: normal, as: UTF8.self)).isEmpty)

        let challenge = Data("<html><head><title>Just a moment...</title><script>window._cf_chl_opt={}</script></head></html>".utf8)
        #expect(CloudflareChallengeDetector.isChallenge(challenge))
        let marked = HTTPURLResponse(url: URL(string: "https://wallsflow.com/")!, statusCode: 403, httpVersion: nil,
                                     headerFields: ["cf-mitigated": "challenge"])
        #expect(CloudflareChallengeDetector.isChallenge(Data(), response: marked))
    }

    @Test func legacyClearancesMoveOutOfPreferences() throws {
        let legacy = testDefaults.make(), secure = testDefaults.make()
        let url = URL(string: "https://wallsflow.com/live-wallpapers/")!
        let cookie = try #require(HTTPCookie(properties: [.name: "cf_clearance", .value: "abc123", .domain: ".wallsflow.com",
                                                          .path: "/", .secure: "TRUE", .expires: Date().addingTimeInterval(3600)]))
        CloudflareClearanceStore(defaults: legacy).saveClearance(from: [cookie], for: "wallsflow.com")
        #expect(legacy.data(forKey: "scena.cloudflare.clearances.v2") != nil)

        let persistence = DefaultsClearancePersistence(defaults: secure, key: "migrated")
        let store = CloudflareClearanceStore(persistence: persistence, legacyDefaults: legacy)
        #expect(store.cookieHeader(for: url) == "cf_clearance=abc123")
        #expect(legacy.data(forKey: "scena.cloudflare.clearances.v2") == nil)
        #expect(persistence.load() != nil)

        store.clear(for: "wallsflow.com")
        #expect(persistence.load() == nil)
    }
}
