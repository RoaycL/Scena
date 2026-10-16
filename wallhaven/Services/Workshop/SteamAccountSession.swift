//
//  SteamAccountSession.swift
//  wallhaven
//
//  SteamKit 扫码与钥匙串恢复；短期社区 Cookie 仅保留在内存。
//  保留 Steam 官方网页登录入口，兼容已有的 WebKit 会话。
//

import Combine
import Foundation
import WebKit

enum SteamSessionError: LocalizedError {
    case notLoggedIn
    case expired
    case rateLimited
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: "请先在设置中登录 Steam 账号。"
        case .expired: "Steam 登录已过期，请重新登录。"
        case .rateLimited: "请求过于频繁，Steam 暂时限制了访问，请稍后再试。"
        case .failed(let message): message
        }
    }
}

final class SteamAccountSession: ObservableObject {
    static let shared = SteamAccountSession()

    @Published private(set) var steamID: String?
    @Published private(set) var personaName: String?
    @Published private(set) var loginState: SteamLoginState = .idle

    var isLoggedIn: Bool { steamID != nil }
    var supportsQRCode: Bool { authenticator.isAvailable }
    var hasRememberedAccount: Bool { nativeCredential != nil && !defaults.bool(forKey: Self.signedOutKey) }
    var sessionIdentifier: UUID { generation }

    private var loginSecure: String?
    private var sessionID: String?
    private var lastRequestAt = Date.distantPast
    /// 两次请求之间的最小间隔
    private let minInterval: TimeInterval
    private var requestInFlight = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private let authenticator: any SteamAuthenticating
    private let credentials: any SteamCredentialStoring
    private let defaults: UserDefaults
    private let readCookies: @MainActor () async -> [HTTPCookie]
    private let deleteCookies: @MainActor () async -> Void
    private let fetchPersonaName: Bool
    private var nativeCredential: SteamCredential?
    private var credentialsLoaded = false
    private var accessExpires = Date.distantPast
    private var rejectedWebCookie: String?
    private var generation = UUID()
    private var loginTask: Task<Void, Never>?
    private var restoreTask: Task<Bool, Never>?
    private var restoreID: UUID?
    private static let signedOutKey = "steam.auth.signedOut.v1"
    private static let loginIDKey = "steam.auth.loginID.v1"

    private let session: URLSession
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        // Cookie 由我们手动带上，不和系统共享
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }

    init(authenticator: (any SteamAuthenticating)? = nil, credentials: (any SteamCredentialStoring)? = nil,
         defaults: UserDefaults = .standard,
         fetchPersonaName: Bool = true,
         session: URLSession? = nil, requestInterval: TimeInterval = 1.2,
         readCookies: @escaping @MainActor () async -> [HTTPCookie] = { await WKWebsiteDataStore.default().httpCookieStore.allCookies() },
         deleteCookies: @escaping @MainActor () async -> Void = {
            let store = WKWebsiteDataStore.default().httpCookieStore
            for cookie in await store.allCookies() where SteamAccountSession.isSteamDomain(cookie.domain) {
                await store.deleteCookie(cookie)
            }
         }) {
        self.authenticator = authenticator ?? SteamServiceClient()
        self.credentials = credentials ?? SteamKeychain()
        self.defaults = defaults
        self.fetchPersonaName = fetchPersonaName
        self.session = session ?? Self.makeSession()
        minInterval = requestInterval
        self.readCookies = readCookies
        self.deleteCookies = deleteCookies
    }

    static let loginURL = URL(string: "https://steamcommunity.com/login/home/?goto=")!

    // MARK: - Authentication

    private var loginID: UInt32 {
        if let number = defaults.object(forKey: Self.loginIDKey) as? NSNumber,
           number.uint64Value > 0, number.uint64Value <= UInt32.max { return number.uint32Value }
        let value = UInt32.random(in: 1...UInt32.max)
        defaults.set(value, forKey: Self.loginIDKey)
        return value
    }

    func beginQRCodeLogin() {
        cancelAuthentication()
        generation = UUID()
        let token = generation
        loginState = .connecting
        loginTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await authenticator.authenticate(.init(method: "qr", loginId: loginID)) { [weak self] url in
                    guard let self, generation == token else { return }
                    loginState = .qr(url)
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                loginTask = nil
                try accept(result)
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                loginState = .failed(error.localizedDescription)
            }
            if generation == token { loginTask = nil }
        }
    }

    func cancelAuthentication() {
        if loginState.isBusy { generation = UUID() }
        loginTask?.cancel()
        loginTask = nil
        restoreTask?.cancel()
        restoreTask = nil
        restoreID = nil
        loginState = isLoggedIn ? .signedIn : .idle
    }

    /// 共享恢复任务：订阅同步与并发操作不会各启动一个 CM 登录。
    @discardableResult
    func ensureAuthenticated(forceRefresh: Bool = false) async -> Bool {
        // 等待扫码时，后台同步不能用旧网页登录会话覆盖用户的登录选择。
        if loginTask != nil { return isLoggedIn }
        do {
            if !credentialsLoaded {
                nativeCredential = defaults.bool(forKey: Self.signedOutKey) ? nil : try credentials.load()
                credentialsLoaded = true
            }
        } catch {
            loginState = .failed(error.localizedDescription)
            return false
        }
        guard let credential = nativeCredential else {
            if isLoggedIn { return true }
            return await restoreWebCookies()
        }
        if !forceRefresh, isLoggedIn, accessExpires > Date().addingTimeInterval(120) { return true }
        if let restoreTask { return await restoreTask.value }
        guard loginTask == nil else { return false }
        let token = generation
        let operationID = UUID()
        restoreID = operationID
        loginState = .restoring
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            do {
                let result = try await authenticator.authenticate(.init(method: "restore", loginId: loginID, credential: credential)) { _ in }
                try Task.checkCancellation()
                guard generation == token else { return false }
                guard result.steamId == credential.steamID,
                      result.accountName.lowercased() == credential.accountName.lowercased() else {
                    throw SteamAuthenticationError.protocolFailure
                }
                try accept(result)
                return true
            } catch {
                guard generation == token, !Task.isCancelled else { return false }
                if let failure = error as? SteamAuthenticationError, failure.invalidatesCredentials {
                    defaults.set(true, forKey: Self.signedOutKey)
                    try? credentials.remove()
                    nativeCredential = nil
                }
                clear(invalidate: true)
                loginState = .failed(error.localizedDescription)
                return false
            }
        }
        restoreTask = task
        let result = await task.value
        if restoreID == operationID { restoreTask = nil; restoreID = nil }
        return result
    }

    /// 扫码登录的账号能直接从 Steam CDN 下载工坊内容（网页登录没有可用于下载的凭据）
    var canDownloadContent: Bool {
        // 启动后还没恢复登录时也要知道有没有扫码凭据，否则第一批下载会误退回 steamcmd
        if !credentialsLoaded, !defaults.bool(forKey: Self.signedOutKey), let stored = try? credentials.load() {
            nativeCredential = stored
            credentialsLoaded = true
        }
        return hasRememberedAccount && authenticator.isAvailable
    }

    /// 下载用的凭据：先确认登录有效（必要时续签，令牌可能轮换），再取最新的持久令牌。
    /// 下载用另一个 LoginID，和订阅同步的连接同时在线时不会互相踢下线
    func contentCredential() async -> (credential: SteamCredential, loginID: UInt32)? {
        guard await ensureAuthenticated(), let nativeCredential else { return nil }
        let downloadID = loginID &+ 1
        return (nativeCredential, downloadID == 0 ? 1 : downloadID)
    }

    private func accept(_ result: SteamAuthenticationResult) throws {
        try result.validate()
        // 原子更新钥匙串成功后才发布登录成功，不能悄悄退化成一次性会话。
        try credentials.save(result.credential)
        if let steamID, steamID != result.steamId { generation = UUID() }
        nativeCredential = result.credential
        credentialsLoaded = true
        defaults.set(false, forKey: Self.signedOutKey)
        accessExpires = Date(timeIntervalSince1970: result.expiresAt)
        loginSecure = "\(result.steamId)%7C%7C\(result.accessToken)"
        sessionID = nil
        personaName = result.accountName
        steamID = result.steamId
        loginState = .signedIn
    }

    // MARK: - Web login compatibility

    /// 用户明确选择网页登录；成功后停用先前的原生凭据，避免重启后切回旧账号。
    @discardableResult
    func refreshFromCookies() async -> Bool {
        let token = generation
        let cookies = await readCookies()
        guard generation == token, let parsed = Self.parseCookies(cookies), parsed.secure != rejectedWebCookie else { return false }
        cancelAuthentication()
        generation = UUID()
        defaults.set(true, forKey: Self.signedOutKey)
        try? credentials.remove()
        nativeCredential = nil
        credentialsLoaded = true
        applyWebCookies(parsed)
        return true
    }

    private func restoreWebCookies() async -> Bool {
        let token = generation
        let cookies = await readCookies()
        guard generation == token, !Task.isCancelled,
              let parsed = Self.parseCookies(cookies), parsed.secure != rejectedWebCookie else { return false }
        applyWebCookies(parsed)
        return true
    }

    private func applyWebCookies(_ parsed: (id: String, secure: String, session: String?)) {
        if let steamID, steamID != parsed.id { generation = UUID() }
        loginSecure = parsed.secure
        sessionID = parsed.session
        accessExpires = .distantPast
        personaName = nil
        steamID = parsed.id
        loginState = .signedIn
        if fetchPersonaName { Task { await loadPersonaName() } }
    }

    nonisolated static func isCommunityDomain(_ value: String) -> Bool {
        let domain = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domain == "steamcommunity.com" || domain.hasSuffix(".steamcommunity.com")
    }

    nonisolated private static func isSteamDomain(_ value: String) -> Bool {
        let domain = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return isCommunityDomain(domain) || domain == "steampowered.com" || domain.hasSuffix(".steampowered.com")
    }

    nonisolated static func parseCookies(_ cookies: [HTTPCookie]) -> (id: String, secure: String, session: String?)? {
        let community = cookies.filter { isCommunityDomain($0.domain) && ($0.expiresDate ?? .distantFuture) > Date() }
        guard let secure = community.first(where: { $0.name == "steamLoginSecure" })?.value,
              !secure.contains(where: { $0.isNewline || $0 == ";" }),
              (secure.removingPercentEncoding ?? secure).components(separatedBy: "||").count == 2,
              !(secure.removingPercentEncoding ?? secure).hasSuffix("||"),
              let id = (secure.removingPercentEncoding ?? secure).components(separatedBy: "||").first,
              id.count == 17, id.allSatisfy(\.isNumber), UInt64(id) != nil else { return nil }
        let session = community.first(where: { $0.name == "sessionid" })?.value
        guard session?.contains(where: { $0.isNewline || $0 == ";" }) != true else { return nil }
        return (id, secure, session)
    }

    func logout() async {
        cancelAuthentication()
        generation = UUID()
        let token = generation
        // 即使钥匙串暂时锁住，重启后也不能自动恢复用户已经退出的账号。
        defaults.set(true, forKey: Self.signedOutKey)
        var failure: Error?
        do { try credentials.remove() } catch { failure = error }
        nativeCredential = nil
        credentialsLoaded = true
        clear()
        await deleteCookies()
        guard generation == token else { return }
        loginState = failure.map { .failed($0.localizedDescription) } ?? .idle
    }

    private func clear(invalidate: Bool = false) {
        if invalidate { generation = UUID() }
        steamID = nil
        personaName = nil
        loginSecure = nil
        sessionID = nil
        accessExpires = .distantPast
        loginState = .idle
    }

    private var cookieHeader: String? {
        guard let loginSecure else { return nil }
        if sessionID == nil {
            // sessionid 是双提交式 CSRF 校验，缺失时生成一个随机值即可
            sessionID = (0..<12).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        }
        return "steamLoginSecure=\(loginSecure); sessionid=\(sessionID ?? "")"
    }

    // MARK: - API

    private func loadPersonaName() async {
        guard let steamID, let url = URL(string: "https://steamcommunity.com/profiles/\(steamID)/?xml=1") else { return }
        guard let (data, _) = try? await session.data(from: url) else { return }
        guard self.steamID == steamID else { return }
        let xml = String(decoding: data, as: UTF8.self)
        if let match = xml.firstMatch(of: /<steamID><!\[CDATA\[(.*?)\]\]><\/steamID>/) {
            personaName = String(match.1)
        }
    }

    /// 订阅页上的条目（标题和预览图直接取自页面，公开详情接口查不到的条目也能显示）
    nonisolated struct SubscriptionEntry: Sendable {
        let id: String
        let title: String?
        let previewURL: URL?
    }

    struct SubscriptionList {
        var entries: [SubscriptionEntry] = []
        /// 页面上显示的订阅总数（"Showing 1-30 of 205 entries"）
        var reportedTotal: Int?
    }

    /// 读取账号订阅的 Wallpaper Engine 条目（按订阅页逐页读取，限速）
    func subscriptions() async throws -> SubscriptionList {
        guard await ensureAuthenticated() else { throw SteamSessionError.notLoggedIn }
        guard let steamID else { throw SteamSessionError.notLoggedIn }
        let token = generation
        var list = SubscriptionList()
        var seen = Set<String>()
        for page in 1...200 {
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            var components = URLComponents(string: "https://steamcommunity.com/profiles/\(steamID)/myworkshopfiles/")!
            components.queryItems = [
                .init(name: "appid", value: WorkshopConstants.appID),
                .init(name: "browsefilter", value: "mysubscriptions"),
                .init(name: "sortmethod", value: "subscriptiondate"),
                .init(name: "numperpage", value: "30"),
                .init(name: "p", value: String(page)),
            ]
            let html = try await getHTML(components.urlEncodingPlus!)
            guard generation == token else { throw CancellationError() }
            if list.reportedTotal == nil, let match = html.firstMatch(of: /of ([\d,]+) entries/) {
                list.reportedTotal = Int(match.1.replacingOccurrences(of: ",", with: ""))
            }

            let pageEntries = Self.parseSubscriptionPage(html)
            let fresh = pageEntries.filter { seen.insert($0.id).inserted }
            if fresh.isEmpty { break }
            list.entries += fresh
            // 以页面给出的总数为准判断是否读完
            if let total = list.reportedTotal, list.entries.count >= total { break }
        }
        return list
    }

    /// 订阅页每个条目的容器 id 为 Subscription<ID>；按容器切块，从块里取标题和预览图
    nonisolated private static func parseSubscriptionPage(_ html: String) -> [SubscriptionEntry] {
        let starts = html.matches(of: /id="Subscription(\d+)"/)
        if starts.isEmpty {
            // 兜底：页面结构变化时只取 ID
            var seen = Set<String>()
            return html.matches(of: /sharedfiles\/filedetails\/\?id=(\d+)/)
                .map { String($0.1) }
                .filter { seen.insert($0).inserted }
                .map { SubscriptionEntry(id: $0, title: nil, previewURL: nil) }
        }
        return starts.enumerated().map { index, match in
            let blockEnd = index + 1 < starts.count ? starts[index + 1].range.lowerBound : html.endIndex
            let block = html[match.range.lowerBound..<blockEnd]
            let title = block.firstMatch(of: /class="workshopItemTitle[^"]*"[^>]*>([^<]+)</)
                .map { String($0.1).trimmingCharacters(in: .whitespacesAndNewlines) }
            let preview = block.firstMatch(of: /class="workshopItemPreviewImage[^"]*"[^>]*src="([^"]+)"/)
                ?? block.firstMatch(of: /src="([^"]+)"[^>]*class="workshopItemPreviewImage/)
            return SubscriptionEntry(
                id: String(match.1),
                title: title.map(Self.decodeEntities),
                previewURL: preview.flatMap { URL(string: Self.decodeEntities(String($0.1))) }
            )
        }
    }

    nonisolated private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    func subscribe(_ id: String) async throws {
        try await postSharedFile(action: "subscribe", id: id)
    }

    func unsubscribe(_ id: String) async throws {
        try await postSharedFile(action: "unsubscribe", id: id)
    }

    private func postSharedFile(action: String, id: String, retry: Bool = true) async throws {
        let token = generation
        guard await ensureAuthenticated() else { throw SteamSessionError.notLoggedIn }
        guard generation == token else { throw CancellationError() }
        guard let cookie = cookieHeader, let sessionID else { throw SteamSessionError.notLoggedIn }
        var request = URLRequest(url: URL(string: "https://steamcommunity.com/sharedfiles/\(action)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://steamcommunity.com", forHTTPHeaderField: "Origin")
        request.setValue("https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)", forHTTPHeaderField: "Referer")
        request.httpBody = "id=\(id)&appid=\(WorkshopConstants.appID)&sessionid=\(sessionID)".data(using: .utf8)

        let data = try await perform(request)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let success = (json?["success"] as? NSNumber)?.intValue ?? 0
        // 1 = 成功；对已订阅的条目再订阅也会返回成功
        guard success == 1 else {
            if success == 0 || String(decoding: data, as: UTF8.self).contains("login") {
                if retry, nativeCredential != nil, await ensureAuthenticated(forceRefresh: true), generation == token {
                    return try await postSharedFile(action: action, id: id, retry: false)
                }
                guard generation == token else { throw CancellationError() }
                throw SteamSessionError.expired
            }
            throw SteamSessionError.failed("Steam 返回错误（\(success)）。")
        }
    }

    private func getHTML(_ url: URL, retry: Bool = true) async throws -> String {
        let token = generation
        guard let cookie = cookieHeader else { throw SteamSessionError.notLoggedIn }
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let html = String(decoding: try await perform(request), as: UTF8.self)
        // 会话失效时 Steam 会把页面重定向到登录页
        if html.contains("g_steamID = false") {
            if retry, nativeCredential != nil, await ensureAuthenticated(forceRefresh: true) {
                guard generation == token else { throw CancellationError() }
                return try await getHTML(url, retry: false)
            }
            guard generation == token else { throw CancellationError() }
            rejectedWebCookie = loginSecure
            clear(invalidate: true)
            loginState = .failed(SteamSessionError.expired.localizedDescription)
            throw SteamSessionError.expired
        }
        return html
    }

    /// 串行 + 限速执行请求
    private func perform(_ request: URLRequest, retry: Bool = true) async throws -> Data {
        let token = generation
        let (data, response) = try await send(request, generation: token)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 { throw SteamSessionError.rateLimited }
        var request = request
        if status == 401 || status == 403 {
            if retry, nativeCredential != nil, await ensureAuthenticated(forceRefresh: true), generation == token,
               loginSecure != nil {
                updateCredentials(in: &request)
                return try await perform(request, retry: false)
            }
            guard generation == token else { throw CancellationError() }
            if status == 403 {
                throw SteamSessionError.failed("Steam 拒绝访问此内容，请检查条目权限和 Steam 内容偏好。")
            }
            rejectedWebCookie = loginSecure
            clear(invalidate: true)
            loginState = .failed(SteamSessionError.expired.localizedDescription)
            throw SteamSessionError.expired
        }
        guard (200..<300).contains(status) else { throw SteamSessionError.failed("Steam 请求失败（\(status)）。") }
        return data
    }

    private func send(_ original: URLRequest, generation token: UUID) async throws -> (Data, URLResponse) {
        if requestInFlight {
            await withCheckedContinuation { requestWaiters.append($0) }
        } else {
            requestInFlight = true
        }
        defer {
            if requestWaiters.isEmpty { requestInFlight = false } else { requestWaiters.removeFirst().resume() }
        }
        let wait = minInterval - Date().timeIntervalSince(lastRequestAt)
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        lastRequestAt = Date()

        var request = original
        updateCredentials(in: &request)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        // /profiles/<ID>/ 会重定向到自定义 URL，重定向时手动设置的 Cookie 头需要重新带上
        let delegate = request.value(forHTTPHeaderField: "Cookie").map(RedirectCookieDelegate.init)
        let (data, response) = try await session.data(for: request, delegate: delegate)
        guard generation == token else { throw CancellationError() }
        return (data, response)
    }

    private func updateCredentials(in request: inout URLRequest) {
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        guard request.httpMethod == "POST", let body = request.httpBody,
              let query = String(data: body, encoding: .utf8) else { return }
        var form = URLComponents()
        form.percentEncodedQuery = query
        form.queryItems = form.queryItems?.map {
            $0.name == "sessionid" ? URLQueryItem(name: $0.name, value: sessionID) : $0
        }
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
    }
}

/// 重定向到 steamcommunity.com 时保留登录 Cookie
nonisolated private final class RedirectCookieDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let cookie: String

    init(_ cookie: String) {
        self.cookie = cookie
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        var request = request
        if let host = request.url?.host, SteamAccountSession.isCommunityDomain(host) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        } else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
