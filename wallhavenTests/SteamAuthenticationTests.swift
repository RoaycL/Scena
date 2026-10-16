import Foundation
import Testing
@testable import wallhaven

@MainActor
private final class MemorySteamCredentials: SteamCredentialStoring {
    var value: SteamCredential?
    var saveError: SteamAuthenticationError?
    var removeError: SteamAuthenticationError?
    var saves = 0
    var removals = 0
    func load() throws -> SteamCredential? { value }
    func save(_ credential: SteamCredential) throws {
        if let saveError { throw saveError }
        value = credential; saves += 1
    }
    func remove() throws {
        removals += 1
        if let removeError { throw removeError }
        value = nil
    }
}

nonisolated private final class SteamHTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Int, String)]
    private var recorded: [URLRequest] = []
    init(_ responses: [(Int, String)]) { self.responses = responses }
    var requests: [URLRequest] { lock.withLock { recorded } }
    func respond(to request: URLRequest) -> (Int, String) {
        lock.withLock {
            recorded.append(request)
            return responses.isEmpty ? (500, "") : responses.removeFirst()
        }
    }
}

nonisolated private final class SteamFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var fixture: SteamHTTPFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.lock.withLock({ Self.fixture }) else { return }
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        let (status, text) = fixture.respond(to: captured)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension SteamAuthenticationTests {
    private func fixtureSession(_ fixture: SteamHTTPFixture) -> URLSession {
        SteamFixtureProtocol.lock.withLock { SteamFixtureProtocol.fixture = fixture }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SteamFixtureProtocol.self]
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    @Test func expiredRequestRetriesWithFreshCookieAndMatchingCSRFBody() async throws {
        let store = MemorySteamCredentials(), auth = SteamAuthStub()
        store.value = SteamAuthStub.result(token: "z").credential
        let fixture = SteamHTTPFixture([(401, ""), (200, "{\"success\":1}")])
        let session = fixtureSession(fixture)
        defer { session.invalidateAndCancel() }
        let account = makeAccount(auth: auth, store: store, defaults: preferences(), session: session)
        try await account.subscribe("12345")
        #expect(auth.requests.count == 2 && fixture.requests.count == 2)
        func csrf(_ request: URLRequest) -> String? {
            var components = URLComponents()
            components.percentEncodedQuery = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
            return components.queryItems?.first { $0.name == "sessionid" }?.value
        }
        let first = fixture.requests[0], second = fixture.requests[1]
        #expect(csrf(first) != csrf(second))
        let renewed = try #require(csrf(second))
        #expect(second.value(forHTTPHeaderField: "Cookie")?.contains("sessionid=\(renewed)") == true)
    }

    @Test func repeatedUnauthorizedResponseIsBoundedToOneRetry() async throws {
        let store = MemorySteamCredentials(), auth = SteamAuthStub()
        store.value = SteamAuthStub.result().credential
        let fixture = SteamHTTPFixture([(401, ""), (401, "")])
        let session = fixtureSession(fixture)
        defer { session.invalidateAndCancel() }
        let account = makeAccount(auth: auth, store: store, defaults: preferences(), session: session)
        await #expect(throws: SteamSessionError.self) { try await account.subscribe("12345") }
        #expect(fixture.requests.count == 2 && auth.requests.count == 2)
        #expect(!account.isLoggedIn)
    }

    @Test func forbiddenContentDoesNotLogOutAValidAccount() async throws {
        let store = MemorySteamCredentials(), auth = SteamAuthStub()
        store.value = SteamAuthStub.result().credential
        let fixture = SteamHTTPFixture([(403, ""), (403, "")])
        let session = fixtureSession(fixture)
        defer { session.invalidateAndCancel() }
        let account = makeAccount(auth: auth, store: store, defaults: preferences(), session: session)
        await #expect(throws: SteamSessionError.self) { try await account.subscribe("12345") }
        #expect(account.isLoggedIn && store.value != nil && store.removals == 0)
        #expect(fixture.requests.count == 2)
    }
}

@MainActor
private final class SteamAuthStub: SteamAuthenticating {
    var isAvailable = true
    var requests: [SteamServiceRequest] = []
    var response: Result<SteamAuthenticationResult, Error> = .success(SteamAuthStub.result())
    var delay: Duration = .milliseconds(20)
    var ignoresCancellation = false
    func authenticate(_ request: SteamServiceRequest, onChallenge: @escaping @MainActor (URL) -> Void) async throws -> SteamAuthenticationResult {
        requests.append(request)
        if request.method == "qr" { onChallenge(URL(string: "https://s.team/q/1/test-fixture")!) }
        if ignoresCancellation { try? await Task.sleep(for: delay) } else { try await Task.sleep(for: delay) }
        return try response.get()
    }
    static func result(token: Character = "a", id: String = "76561198000000001") -> SteamAuthenticationResult {
        .init(accountName: "fixture", steamId: id, refreshToken: String(repeating: String(token), count: 64),
              accessToken: String(repeating: String(token).uppercased(), count: 64), expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970)
    }
}

@MainActor
@Suite(.serialized)
struct SteamAuthenticationTests {
    private func makeAccount(auth: SteamAuthStub, store: MemorySteamCredentials, defaults: UserDefaults,
                             session: URLSession? = nil, cookies: [HTTPCookie] = []) -> SteamAccountSession {
        SteamAccountSession(authenticator: auth, credentials: store, defaults: defaults, fetchPersonaName: false,
            session: session, requestInterval: 0, readCookies: { cookies }, deleteCookies: {})
    }

    private let testDefaults = TestDefaults()
    private func preferences() -> UserDefaults { testDefaults.make() }

    @Test func concurrentRestoreSharesOneLoginAndRotatesPersistedToken() async throws {
        let store = MemorySteamCredentials(), auth = SteamAuthStub(), defaults = preferences()
        store.value = SteamAuthStub.result(token: "z").credential
        let account = makeAccount(auth: auth, store: store, defaults: defaults)
        async let first = account.ensureAuthenticated()
        async let second = account.ensureAuthenticated()
        let results = await (first, second)
        #expect(results.0 && results.1)
        #expect(auth.requests.count == 1)
        #expect(store.value == SteamAuthStub.result().credential)
        #expect(account.steamID == "76561198000000001")
        #expect(await account.ensureAuthenticated())
        #expect(auth.requests.count == 1)
        auth.response = .success(SteamAuthStub.result(token: "b"))
        #expect(await account.ensureAuthenticated(forceRefresh: true))
        #expect(auth.requests.count == 2 && auth.requests[0].loginId != 0)
        #expect(auth.requests[0].loginId == auth.requests[1].loginId)
        #expect(auth.requests[1].refreshToken == String(repeating: "a", count: 64))
        #expect(store.value?.refreshToken == String(repeating: "b", count: 64))
        #expect(!defaults.dictionaryRepresentation().values.contains { ($0 as? String) == store.value?.refreshToken })
    }

    @Test func transientFailurePreservesCredentialAndCanRecover() async throws {
        let store = MemorySteamCredentials(), auth = SteamAuthStub()
        let original = SteamAuthStub.result().credential
        store.value = original
        auth.response = .failure(SteamAuthenticationError.connection)
        let account = makeAccount(auth: auth, store: store, defaults: preferences())
        #expect(!(await account.ensureAuthenticated()))
        #expect(store.value == original && store.removals == 0)
        #expect(account.hasRememberedAccount && !account.isLoggedIn)
        auth.response = .success(SteamAuthStub.result(token: "b"))
        #expect(await account.ensureAuthenticated(forceRefresh: true))
        #expect(account.isLoggedIn)
    }

    @Test func revokedCredentialDoesNotRestoreAfterRestartEvenIfKeychainDeleteFails() async throws {
        let store = MemorySteamCredentials(), auth = SteamAuthStub(), defaults = preferences()
        store.value = SteamAuthStub.result().credential
        store.removeError = .keychain(-25308)
        auth.response = .failure(SteamAuthenticationError.credentialsExpired)
        let account = makeAccount(auth: auth, store: store, defaults: defaults)
        #expect(!(await account.ensureAuthenticated()))
        #expect(!account.hasRememberedAccount)
        let restartedAuth = SteamAuthStub()
        let restarted = makeAccount(auth: restartedAuth, store: store, defaults: defaults)
        #expect(!(await restarted.ensureAuthenticated()))
        #expect(restartedAuth.requests.isEmpty)
    }

    @Test func logoutPreventsLateUncooperativeSuccessFromSavingOrRevivingAccount() async throws {
        let store = MemorySteamCredentials(), auth = SteamAuthStub(), defaults = preferences()
        store.value = SteamAuthStub.result().credential
        auth.delay = .seconds(1)
        auth.ignoresCancellation = true
        let account = makeAccount(auth: auth, store: store, defaults: defaults)
        let pending = Task { await account.ensureAuthenticated() }
        for _ in 0..<100 {
            if !auth.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(!auth.requests.isEmpty)
        await account.logout()
        #expect(!(await pending.value))
        #expect(!account.isLoggedIn && store.value == nil && store.saves == 0)
        #expect(!(await account.ensureAuthenticated()))
        #expect(auth.requests.count == 1)
    }

    @Test func restoreCannotSwitchToAnotherAccountOrSaveMalformedResult() async throws {
        let store = MemorySteamCredentials(), auth = SteamAuthStub()
        let original = SteamAuthStub.result().credential
        store.value = original
        auth.response = .success(SteamAuthStub.result(id: "76561198000000002"))
        let account = makeAccount(auth: auth, store: store, defaults: preferences())
        #expect(!(await account.ensureAuthenticated()))
        #expect(store.value == original && store.saves == 0 && !account.isLoggedIn)
        let malformed = SteamAuthenticationResult(accountName: "fixture", steamId: original.steamID,
            refreshToken: original.refreshToken, accessToken: "bad\r\nCookie: injected", expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970)
        #expect(throws: SteamAuthenticationError.self) { try malformed.validate() }
    }

    @Test func qrLoginPersistsBeforeReportingSuccessAndCancellationIsQuiet() async throws {
        let store = MemorySteamCredentials(), auth = SteamAuthStub()
        let account = makeAccount(auth: auth, store: store, defaults: preferences())
        account.beginQRCodeLogin()
        for _ in 0..<100 {
            if account.loginState == .signedIn { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(account.loginState == .signedIn && store.saves == 1 && account.isLoggedIn)
        let secondStore = MemorySteamCredentials()
        auth.delay = .seconds(1)
        let second = makeAccount(auth: auth, store: secondStore, defaults: preferences())
        second.beginQRCodeLogin()
        await Task.yield()
        second.cancelAuthentication()
        try await Task.sleep(for: .milliseconds(30))
        #expect(second.loginState == .idle && !second.isLoggedIn && secondStore.saves == 0)
    }

    @Test func failedKeychainSaveCannotLookLikePersistentLoginSucceeded() async throws {
        let store = MemorySteamCredentials(), auth = SteamAuthStub()
        store.saveError = .keychain(-25291)
        let account = makeAccount(auth: auth, store: store, defaults: preferences())
        account.beginQRCodeLogin()
        for _ in 0..<100 {
            if case .failed = account.loginState { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard case .failed = account.loginState else { Issue.record("Keychain failure was not surfaced"); return }
        #expect(!account.isLoggedIn && store.value == nil)
    }

    @Test func communityCookieParsingHandlesBothSeparatorsAndRejectsLookalikeDomains() throws {
        func cookie(domain: String, value: String, expires: Date = .distantFuture) throws -> HTTPCookie {
            try #require(HTTPCookie(properties: [.domain: domain, .path: "/", .name: "steamLoginSecure", .value: value, .expires: expires]))
        }
        for separator in ["||", "%7C%7C"] {
            let c = try cookie(domain: ".steamcommunity.com", value: "76561198000000001\(separator)token")
            #expect(SteamAccountSession.parseCookies([c])?.id == "76561198000000001")
        }
        #expect(SteamAccountSession.parseCookies([try cookie(domain: "evilsteamcommunity.com", value: "76561198000000001||token")]) == nil)
        #expect(SteamAccountSession.parseCookies([try cookie(domain: ".steamcommunity.com", value: "76561198000000001||token", expires: .distantPast)]) == nil)
        #expect(SteamAccountSession.parseCookies([try cookie(domain: ".steamcommunity.com", value: "76561198000000001||")]) == nil)
    }

    @Test func explicitWebLoginCannotRestorePreviousNativeAccountOnRestart() async throws {
        let store = MemorySteamCredentials(), auth = SteamAuthStub(), defaults = preferences()
        store.value = SteamAuthStub.result().credential
        let cookie = try #require(HTTPCookie(properties: [.domain: ".steamcommunity.com", .path: "/", .name: "steamLoginSecure", .value: "76561198000000002%7C%7Ctoken"]))
        let account = makeAccount(auth: auth, store: store, defaults: defaults, cookies: [cookie])
        #expect(await account.refreshFromCookies())
        #expect(account.steamID == "76561198000000002" && store.value == nil)
        let restarted = makeAccount(auth: auth, store: store, defaults: defaults, cookies: [cookie])
        #expect(await restarted.ensureAuthenticated())
        #expect(restarted.steamID == "76561198000000002" && auth.requests.isEmpty)
    }

    @Test func nativeKeychainRoundTripAndAtomicReplacement() throws {
        let store = SteamKeychain(service: "com.roayc.scena.tests.\(UUID().uuidString)")
        defer { try? store.remove() }
        #expect(try store.load() == nil)
        let first = SteamAuthStub.result().credential
        try store.save(first)
        #expect(try store.load() == first)
        let rotated = SteamAuthStub.result(token: "b").credential
        try store.save(rotated)
        #expect(try store.load() == rotated)
        try store.remove()
        #expect(try store.load() == nil)
    }

    @Test func closingSuccessfulLoginDoesNotInvalidateFreshSession() async throws {
        let store = MemorySteamCredentials(), auth = SteamAuthStub()
        let account = makeAccount(auth: auth, store: store, defaults: preferences())
        account.beginQRCodeLogin()
        for _ in 0..<100 {
            if account.isLoggedIn { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(account.isLoggedIn)
        let epoch = account.sessionIdentifier
        account.cancelAuthentication()
        #expect(account.sessionIdentifier == epoch && account.loginState == .signedIn)
        #expect(await account.ensureAuthenticated())
        #expect(auth.requests.count == 1)
    }

    @Test func backgroundCookieRestoreCannotOverrideAnActiveQRChallenge() async throws {
        let store = MemorySteamCredentials(), auth = SteamAuthStub()
        auth.delay = .seconds(1)
        let cookie = try #require(HTTPCookie(properties: [.domain: ".steamcommunity.com", .path: "/", .name: "steamLoginSecure", .value: "76561198000000002||legacy"]))
        let account = makeAccount(auth: auth, store: store, defaults: preferences(), cookies: [cookie])
        account.beginQRCodeLogin()
        defer { account.cancelAuthentication() }
        #expect(!(await account.ensureAuthenticated()))
        #expect(!account.isLoggedIn)
    }

    @Test func delayedCookieDeletionCannotClearANewerLogin() async throws {
        let store = MemorySteamCredentials(), auth = SteamAuthStub()
        let account = SteamAccountSession(authenticator: auth, credentials: store, defaults: preferences(),
            fetchPersonaName: false, readCookies: { [] }, deleteCookies: { try? await Task.sleep(for: .milliseconds(100)) })
        let logout = Task { await account.logout() }
        await Task.yield()
        account.beginQRCodeLogin()
        await logout.value
        #expect(account.isLoggedIn && account.loginState == .signedIn && store.saves == 1)
    }
}
