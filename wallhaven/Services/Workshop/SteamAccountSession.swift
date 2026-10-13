//
//  SteamAccountSession.swift
//  wallhaven
//
//  Steam 网页会话：用于读取 / 修改账号的创意工坊订阅（双向同步）。
//  用户在 App 内嵌的 Steam 网页里自己登录，App 只读取登录后的会话 Cookie，不接触密码。
//  所有请求串行并限速，避免触发 Steam 的频率限制。
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

    var isLoggedIn: Bool { steamID != nil }

    private var loginSecure: String?
    private var sessionID: String?
    private var lastRequestAt = Date.distantPast
    /// 两次请求之间的最小间隔
    private let minInterval: TimeInterval = 1.2

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        // Cookie 由我们手动带上，不和系统共享
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    private init() {}

    static let loginURL = URL(string: "https://steamcommunity.com/login/home/?goto=")!

    // MARK: - Cookies

    /// 从 WebKit 的 Cookie 存储读取登录状态（登录窗口完成后、App 启动时调用）
    @discardableResult
    func refreshFromCookies() async -> Bool {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let community = cookies.filter { $0.domain.hasSuffix("steamcommunity.com") }
        guard let secure = community.first(where: { $0.name == "steamLoginSecure" })?.value, !secure.isEmpty else {
            clear()
            return false
        }
        loginSecure = secure
        sessionID = community.first(where: { $0.name == "sessionid" })?.value
        // steamLoginSecure 形如 7656119xxxxxxxxxx%7C%7C<token>
        let id = secure.components(separatedBy: "%7C%7C").first ?? secure.components(separatedBy: "||").first
        steamID = id.flatMap { $0.allSatisfy(\.isNumber) ? $0 : nil }
        if steamID != nil, personaName == nil {
            await loadPersonaName()
        }
        return steamID != nil
    }

    func logout() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in await store.allCookies() where cookie.domain.contains("steam") {
            await store.deleteCookie(cookie)
        }
        clear()
    }

    private func clear() {
        steamID = nil
        personaName = nil
        loginSecure = nil
        sessionID = nil
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
        guard let steamID else { throw SteamSessionError.notLoggedIn }
        var list = SubscriptionList()
        var seen = Set<String>()
        for page in 1...200 {
            var components = URLComponents(string: "https://steamcommunity.com/profiles/\(steamID)/myworkshopfiles/")!
            components.queryItems = [
                .init(name: "appid", value: WorkshopConstants.appID),
                .init(name: "browsefilter", value: "mysubscriptions"),
                .init(name: "sortmethod", value: "subscriptiondate"),
                .init(name: "numperpage", value: "30"),
                .init(name: "p", value: String(page)),
            ]
            let html = try await getHTML(components.url!)
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

    private func postSharedFile(action: String, id: String) async throws {
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
                throw SteamSessionError.expired
            }
            throw SteamSessionError.failed("Steam 返回错误（\(success)）。")
        }
    }

    private func getHTML(_ url: URL) async throws -> String {
        guard let cookie = cookieHeader else { throw SteamSessionError.notLoggedIn }
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let html = String(decoding: try await perform(request), as: UTF8.self)
        // 会话失效时 Steam 会把页面重定向到登录页
        if html.contains("g_steamID = false") {
            throw SteamSessionError.expired
        }
        return html
    }

    /// 串行 + 限速执行请求
    private func perform(_ request: URLRequest) async throws -> Data {
        let wait = minInterval - Date().timeIntervalSince(lastRequestAt)
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        lastRequestAt = Date()

        var request = request
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        // /profiles/<ID>/ 会重定向到自定义 URL，重定向时手动设置的 Cookie 头需要重新带上
        let delegate = request.value(forHTTPHeaderField: "Cookie").map(RedirectCookieDelegate.init)
        let (data, response) = try await session.data(for: request, delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 { throw SteamSessionError.rateLimited }
        if status == 401 || status == 403 { throw SteamSessionError.expired }
        guard (200..<400).contains(status) else { throw SteamSessionError.failed("Steam 请求失败（\(status)）。") }
        return data
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
        if request.url?.host?.hasSuffix("steamcommunity.com") == true {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        completionHandler(request)
    }
}
