import Foundation
import Testing
@testable import wallhaven

@MainActor private final class MemoryPixivKeychain: PixivCredentialStoring {
    var value: PixivCredential?
    var failSave = false
    var failRemove = false
    func load() throws -> PixivCredential? { value }
    func save(_ credential: PixivCredential) throws {
        if failSave { throw CocoaError(.fileWriteNoPermission) }
        value = credential
    }
    func remove() throws {
        if failRemove { throw CocoaError(.fileWriteNoPermission) }
        value = nil
    }
}

@MainActor private final class ControlledPixivRequests {
    var requests: [URLRequest] = []
    var pending: [Int: CheckedContinuation<(Data, URLResponse), Error>] = [:]
    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let index = requests.count
        requests.append(request)
        // 故意不响应任务取消，确认旧响应不能覆盖新会话。
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func finish(_ index: Int, status: Int = 200, body: String = #"{"error":false,"body":{"id":"123","name":"Test"}}"#) {
        let response = HTTPURLResponse(url: requests[index].url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        pending.removeValue(forKey: index)?.resume(returning: (Data(body.utf8), response))
    }
}

@MainActor struct PixivSessionTests {
    private let preferences = TestDefaults()
    private func cookie(_ value: String = "123_fake", domain: String = ".pixiv.net", expired: Bool = false) -> HTTPCookie {
        HTTPCookie(properties: [.domain: domain, .path: "/", .name: "PHPSESSID", .value: value,
                               .expires: Date().addingTimeInterval(expired ? -3600 : 3600)])!
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CocoaError(.coderValueNotFound)
    }
    private func account(_ store: MemoryPixivKeychain, _ network: ControlledPixivRequests,
                         defaults: UserDefaults? = nil, vault: PixivCookieVault? = nil,
                         read: @escaping @MainActor () async -> [HTTPCookie]) -> PixivAccountSession {
        PixivAccountSession(keychain: store, defaults: defaults ?? preferences.make(), vault: vault,
                            restoreAutomatically: false, requestLoader: network.load, readCookies: read, deleteCookie: { _ in })
    }

    @Test func invalidCookieCannotPublishLoginOrReachKeychain() async throws {
        let store = MemoryPixivKeychain(), network = ControlledPixivRequests(), vault = PixivCookieVault()
        let candidate = cookie()
        let session = account(store, network, vault: vault, read: { [candidate] })
        let task = Task { await session.refreshFromCookies() }
        try await waitFor { network.pending[0] != nil }
        #expect(!session.isLoggedIn && session.isChecking && vault.header == nil && store.value == nil)
        #expect(network.requests[0].httpShouldHandleCookies == false)
        network.finish(0, status: 401)
        #expect(await task.value == false)
        #expect(!session.isLoggedIn && !session.isPersistent && store.value == nil && session.errorMessage != nil)
    }

    @Test func successfulValidationPublishesAndPersistsOnlyAtCompletion() async throws {
        let store = MemoryPixivKeychain(), network = ControlledPixivRequests(), vault = PixivCookieVault()
        let candidate = cookie()
        let session = account(store, network, vault: vault, read: { [candidate] })
        let task = Task { await session.refreshFromCookies() }
        try await waitFor { network.pending[0] != nil }
        network.finish(0)
        #expect(await task.value)
        #expect(session.isLoggedIn && session.isPersistent && session.userID == "123")
        #expect(store.value?.phpsessid == candidate.value && vault.header == "PHPSESSID=123_fake")
    }

    @Test func logoutRejectsLateSuccessAndLateFailure() async throws {
        for status in [200, 401] {
            let store = MemoryPixivKeychain(), network = ControlledPixivRequests(), vault = PixivCookieVault()
            let candidate = cookie()
            let session = account(store, network, vault: vault, read: { [candidate] })
            let task = Task { await session.refreshFromCookies() }
            try await waitFor { network.pending[0] != nil }
            await session.logout()
            network.finish(0, status: status)
            #expect(await task.value == false)
            #expect(!session.isLoggedIn && vault.header == nil && store.value == nil)
            #expect(session.errorMessage == nil)
        }
    }

    @Test func oldAccountFailureCannotDeleteNewAccount() async throws {
        let store = MemoryPixivKeychain(), network = ControlledPixivRequests()
        var candidates = [cookie("123_old")]
        let session = account(store, network, read: { candidates })
        let old = Task { await session.refreshFromCookies() }
        try await waitFor { network.pending[0] != nil }
        candidates = [cookie("456_new")]
        let new = Task { await session.refreshFromCookies() }
        try await waitFor { network.pending[1] != nil }
        network.finish(1, body: #"{"error":false,"body":{"id":"456","name":"New"}}"#)
        #expect(await new.value)
        network.finish(0, status: 401)
        #expect(await old.value == false)
        #expect(session.userID == "456" && store.value?.phpsessid == "456_new" && session.isLoggedIn)
    }

    @Test func keychainFailureIsTemporaryAndCanBeRetried() async throws {
        let store = MemoryPixivKeychain(), network = ControlledPixivRequests(), defaults = preferences.make()
        store.failSave = true
        let candidate = cookie()
        let session = account(store, network, defaults: defaults, read: { [candidate] })
        let task = Task { await session.refreshFromCookies() }
        try await waitFor { network.pending[0] != nil }
        network.finish(0)
        #expect(await task.value)
        #expect(session.isLoggedIn && !session.isPersistent && session.errorMessage?.contains("仅本次有效") == true)
        let reopened = account(store, network, defaults: defaults, read: { [] })
        #expect(await reopened.checkLoginState() == false)
        store.failSave = false
        #expect(session.retryPersistence())
        #expect(session.isPersistent && session.errorMessage == nil && store.value != nil)
    }

    @Test func restoreWaitsForValidationAndNetworkErrorKeepsRecord() async throws {
        let store = MemoryPixivKeychain(), network = ControlledPixivRequests()
        store.value = PixivCredential(phpsessid: "123_saved", userID: "123", userName: "Old", updatedAt: Date())
        let session = account(store, network, read: { [] })
        #expect(!session.isLoggedIn && session.cookieHeader == nil)
        let task = Task { await session.checkLoginState() }
        try await waitFor { network.pending[0] != nil }
        network.finish(0, status: 503)
        #expect(await task.value == false)
        #expect(store.value != nil && !session.isLoggedIn)
        let retry = Task { await session.checkLoginState() }
        try await waitFor { network.pending[1] != nil }
        network.finish(1)
        #expect(await retry.value && session.isPersistent)
    }

    @Test func logoutTombstoneSurvivesFailedKeychainDeletion() async throws {
        let store = MemoryPixivKeychain(), network = ControlledPixivRequests(), defaults = preferences.make()
        store.value = PixivCredential(phpsessid: "123_saved", userID: nil, userName: nil, updatedAt: Date())
        store.failRemove = true
        let session = account(store, network, defaults: defaults, read: { [] })
        await session.logout()
        #expect(session.errorMessage != nil)
        let reopened = account(store, network, defaults: defaults, read: { [] })
        #expect(await reopened.checkLoginState() == false)
        #expect(network.requests.isEmpty)
    }

    @Test func cookieDomainExpiryAndHeaderInjectionAreRejected() {
        #expect(PixivAccountSession.usableCookie(in: [cookie(domain: "notpixiv.net")]) == nil)
        #expect(PixivAccountSession.usableCookie(in: [cookie(domain: "pixiv.net.evil.example")]) == nil)
        #expect(PixivAccountSession.usableCookie(in: [cookie(expired: true)]) == nil)
        #expect(PixivAccountSession.usableCookie(in: [cookie("valid; another=bad")]) == nil)
        #expect(PixivAccountSession.usableCookie(in: [cookie(domain: "www.pixiv.net")]) != nil)
    }
    @Test func delayedLogoutCannotDeleteNewWebLoginCookies() async throws {
        let store = MemoryPixivKeychain(), network = ControlledPixivRequests()
        var readCount = 0, deleted = 0
        var delayed: CheckedContinuation<[HTTPCookie], Never>?
        let candidate = cookie("456_new")
        let session = PixivAccountSession(keychain: store, defaults: preferences.make(), restoreAutomatically: false,
            requestLoader: network.load, readCookies: {
                readCount += 1
                if readCount == 1 { return await withCheckedContinuation { delayed = $0 } }
                return [candidate]
            }, deleteCookie: { _ in deleted += 1 })
        let logout = Task { await session.logout() }
        try await waitFor { delayed != nil }
        let login = Task { await session.refreshFromCookies() }
        try await waitFor { network.pending[0] != nil }
        network.finish(0, body: #"{"error":false,"body":{"id":"456","name":"New"}}"#)
        #expect(await login.value)
        delayed?.resume(returning: [candidate])
        await logout.value
        #expect(deleted == 0 && session.isLoggedIn && store.value?.phpsessid == "456_new")
    }

    @Test func validatedCookieOnlyGoesToHTTPSPixivAPIHost() {
        let vault = PixivCookieVault()
        vault.publish(PixivCredential(phpsessid: "123_fake", userID: nil, userName: nil, updatedAt: Date()))
        #expect(vault.header(for: URL(string: "https://www.pixiv.net/ajax/user/extra")!) != nil)
        for url in ["http://www.pixiv.net/ajax/user/extra", "https://accounts.pixiv.net/", "https://i.pximg.net/a.jpg", "https://www.pixiv.net.evil.example/"] {
            #expect(vault.header(for: URL(string: url)!) == nil)
        }
    }

}
