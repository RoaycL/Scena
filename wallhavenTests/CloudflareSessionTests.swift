import Foundation
import Testing
@testable import wallhaven

@MainActor struct CloudflareSessionTests {
    private let preferences = TestDefaults()
    private let url = URL(string: "https://wallsflow.com/live-wallpapers/")!
    private func cookie(_ value: String = "fake-clearance", domain: String = ".wallsflow.com", path: String = "/", expired: Bool = false) -> HTTPCookie {
        HTTPCookie(properties: [.domain: domain, .path: path, .name: "cf_clearance", .value: value,
                               .expires: Date().addingTimeInterval(expired ? -3600 : 3600), .secure: "TRUE"])!
    }

    @Test func expiredAndUnrelatedCookiesCannotBecomeClearance() {
        let store = CloudflareClearanceStore(defaults: preferences.make())
        #expect(!store.saveClearance(from: [cookie(expired: true)], for: "wallsflow.com"))
        #expect(!store.saveClearance(from: [cookie(domain: "private.wallsflow.com")], for: "wallsflow.com"))
        #expect(!store.saveClearance(from: [cookie(domain: ".wallsflow.com.evil.example")], for: "wallsflow.com"))
        #expect(store.cookieHeader(for: "wallsflow.com") == nil)
    }

    @Test func originalHostOnlyDomainPathAndExpirySurvivePersistence() throws {
        let defaults = preferences.make(), store = CloudflareClearanceStore(defaults: preferences.make())
        let child = URL(string: "https://private.wallsflow.com/download/item")!
        let scoped = try #require(CloudflareClearanceStore.candidate(from: [cookie(domain: "private.wallsflow.com", path: "/download")], for: child))
        let persisted = CloudflareClearanceStore(defaults: defaults)
        #expect(persisted.save(scoped, for: child))
        let reopened = CloudflareClearanceStore(defaults: defaults)
        #expect(reopened.cookieHeader(for: child) != nil)
        #expect(reopened.cookieHeader(for: URL(string: "https://private.wallsflow.com/download-other")!) == nil)
        #expect(reopened.cookieHeader(for: "wallsflow.com") == nil)
        #expect(reopened.cookieHeader(for: "cloud.wallsflow.com") == nil)
        #expect(reopened.cookieHeader(for: "sub.private.wallsflow.com") == nil)
        #expect(reopened.cookieHeader(for: URL(string: "http://private.wallsflow.com/download/item")!) == nil)
        #expect(store.saveClearance(from: [cookie()], for: "wallsflow.com"))
        #expect(store.cookieHeader(for: "cloud.wallsflow.com") != nil)
        #expect(!CloudflareClearanceStore.isMatchingDomain("private.wallsflow.com", target: "wallsflow.com"))
    }

    @Test func oldCookieDoesNotCloseVerificationAndSameFailureIsNotPolledRepeatedly() async {
        let store = CloudflareClearanceStore(defaults: preferences.make())
        let challenge = CloudflareChallengeRequiredError(domain: "wallsflow.com", challengeURL: url)
        var probes = 0
        let model = CloudflareVerificationModel(store: store) { url, headers in
            probes += 1
            #expect(headers["User-Agent"] == SourceHTTP.userAgent)
            if headers["Cookie"] == "cf_clearance=old" { throw challenge }
        }
        #expect(await model.inspect(cookies: [cookie("old")], challenge: challenge) == false)
        #expect(await model.inspect(cookies: [cookie("old")], challenge: challenge) == false)
        #expect(probes == 1 && store.cookieHeader(for: url) == nil && model.errorMessage != nil)
        #expect(await model.inspect(cookies: [cookie("new")], challenge: challenge))
        #expect(store.cookieHeader(for: url) == "cf_clearance=new")
        #expect(await model.inspect(cookies: [cookie("new")], challenge: challenge) == false)
        #expect(probes == 2)
    }

    @Test func cancelledVerificationCannotSaveLateSuccessfulProbe() async throws {
        let store = CloudflareClearanceStore(defaults: preferences.make())
        var response: CheckedContinuation<Void, Error>?
        let model = CloudflareVerificationModel(store: store) { _, _ in
            try await withCheckedThrowingContinuation { response = $0 }
        }
        let challenge = CloudflareChallengeRequiredError(domain: "wallsflow.com", challengeURL: url)
        let task = Task { await model.inspect(cookies: [cookie()], challenge: challenge) }
        for _ in 0..<200 {
            if response != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let pending = try #require(response)
        model.cancel()
        pending.resume()
        #expect(await task.value == false)
        #expect(store.cookieHeader(for: url) == nil)
    }

    @Test func expiredCookieDoesNotEvenStartProbe() async {
        var probes = 0
        let model = CloudflareVerificationModel(store: CloudflareClearanceStore(defaults: preferences.make())) { _, _ in probes += 1 }
        let challenge = CloudflareChallengeRequiredError(domain: "wallsflow.com", challengeURL: url)
        #expect(await model.inspect(cookies: [cookie(expired: true)], challenge: challenge) == false)
        #expect(probes == 0)
    }

    @Test func successfulVerificationCanBeReusedAfterStoreRestarts() async {
        let defaults = preferences.make(), store = CloudflareClearanceStore(defaults: preferences.make())
        let persistent = CloudflareClearanceStore(defaults: defaults)
        let model = CloudflareVerificationModel(store: persistent) { _, _ in }
        let challenge = CloudflareChallengeRequiredError(domain: "wallsflow.com", challengeURL: url)
        #expect(await model.inspect(cookies: [cookie()], challenge: challenge))
        let restarted = CloudflareClearanceStore(defaults: defaults)
        #expect(restarted.cookieHeader(for: url) == "cf_clearance=fake-clearance")
        #expect(store.cookieHeader(for: url) == nil)
    }

    @Test func challengeIsRecognizedForListAndDownloadAndIsNotTransientRetry() throws {
        let data = Data("<html><title>Just a moment...</title><script>_cf_chl_opt</script></html>".utf8)
        for status in [200, 403, 503] {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: [:])!
            let challenge = try #require(SourceHTTP.challenge(data: data, response: response, pageURL: url))
            #expect(challenge.challengeURL == url)
            let error: any Error = challenge
            #expect(!(error is TransientSourceError))
        }
    }
}
