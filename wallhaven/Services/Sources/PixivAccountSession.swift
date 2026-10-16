//
//  PixivAccountSession.swift
//  wallhaven
//
//  Pixiv 账号会话与系统钥匙串持久化管理。
//  通过内嵌 WKWebView 登录提取 PHPSESSID，并向 Pixiv API 验证用户身份。
//  登录凭证安全保存在钥匙串中，启动时自动恢复并注入 Pixiv 相关的网络请求。
//

import Combine
import Foundation
import LocalAuthentication
import Security
import WebKit

nonisolated struct PixivCredential: Codable, Sendable {
    let phpsessid: String
    var userID: String?
    var userName: String?
    let updatedAt: Date
}

@MainActor protocol PixivCredentialStoring {
    func load() throws -> PixivCredential?
    func save(_ credential: PixivCredential) throws
    func remove() throws
}

@MainActor final class PixivKeychain: PixivCredentialStoring {
    private let service: String

    init(service: String? = nil) {
        self.service = service ?? "\(Bundle.main.bundleIdentifier ?? "com.roayc.wallhaven").pixiv.auth.v1"
    }

    private var query: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "pixiv-account",
            kSecUseAuthenticationContext as String: context
        ]
    }

    func load() throws -> PixivCredential? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SteamAuthenticationError.keychain(status) }
        guard let data = result as? Data, let credential = try? JSONDecoder().decode(PixivCredential.self, from: data) else {
            throw PixivSessionError.invalidResponse
        }
        return credential
    }

    func save(_ credential: PixivCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Scena · Pixiv"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw SteamAuthenticationError.keychain(added) }
        } else if status != errSecSuccess {
            throw SteamAuthenticationError.keychain(status)
        }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SteamAuthenticationError.keychain(status) }
    }
}

/// 网络图片请求可从后台读取；这里只发布已经通过服务端验证的凭据。
nonisolated final class PixivCookieVault: @unchecked Sendable {
    static let shared = PixivCookieVault()
    private let lock = NSLock()
    private var value: String?
    var header: String? { lock.withLock { value.map { "PHPSESSID=\($0)" } } }
    func header(for url: URL) -> String? {
        guard url.scheme == "https", url.host?.lowercased() == "www.pixiv.net" else { return nil }
        return header
    }
    var isAuthenticated: Bool { lock.withLock { value != nil } }
    func publish(_ credential: PixivCredential?) { lock.withLock { value = credential?.phpsessid } }
}

nonisolated enum PixivSessionError: LocalizedError {
    case invalidResponse, expired, connection
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "无法确认 Pixiv 登录状态，请重试。"
        case .expired: "Pixiv 登录会话已过期，请在网页中重新登录。"
        case .connection: "暂时无法连接 Pixiv，请稍后重试。"
        }
    }
}

@MainActor final class PixivAccountSession: ObservableObject {
    static let shared = PixivAccountSession(vault: .shared)
    static let loginURL = URL(string: "https://accounts.pixiv.net/login")!
    private static let signedOutKey = "pixiv.auth.signedOut.v1"

    @Published private(set) var isLoggedIn = false
    @Published private(set) var isPersistent = false
    @Published private(set) var userID: String?
    @Published private(set) var userName: String?
    @Published private(set) var isChecking = false
    @Published private(set) var errorMessage: String?

    private let keychain: any PixivCredentialStoring
    private let session: URLSession
    private let requestLoader: @MainActor (URLRequest) async throws -> (Data, URLResponse)
    private let defaults: UserDefaults
    private let vault: PixivCookieVault
    private let readCookies: @MainActor () async -> [HTTPCookie]
    private let deleteCookie: @MainActor (HTTPCookie) async -> Void
    private var credential: PixivCredential?
    private var savedCandidate: PixivCredential?
    private var generation = UUID()
    private var validationTask: Task<Bool, Never>?

    init(keychain: (any PixivCredentialStoring)? = nil, session: URLSession? = nil,
         defaults: UserDefaults = .standard, vault: PixivCookieVault? = nil, restoreAutomatically: Bool = true,
         requestLoader: (@MainActor (URLRequest) async throws -> (Data, URLResponse))? = nil,
         readCookies: @escaping @MainActor () async -> [HTTPCookie] = { await WKWebsiteDataStore.default().httpCookieStore.allCookies() },
         deleteCookie: @escaping @MainActor (HTTPCookie) async -> Void = { await WKWebsiteDataStore.default().httpCookieStore.deleteCookie($0) }) {
        self.keychain = keychain ?? PixivKeychain()
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            self.session = URLSession(configuration: config)
        }
        let networkSession = self.session
        self.requestLoader = requestLoader ?? { try await networkSession.data(for: $0) }
        self.defaults = defaults
        self.vault = vault ?? PixivCookieVault()
        self.readCookies = readCookies
        self.deleteCookie = deleteCookie
        guard !defaults.bool(forKey: Self.signedOutKey) else { return }
        do { savedCandidate = try self.keychain.load() }
        catch { errorMessage = "无法读取 Pixiv 钥匙串凭据，请重新登录。" }
        if restoreAutomatically, let savedCandidate {
            beginValidation(savedCandidate)
        }
    }

    nonisolated var cookieHeader: String? { vault.header }

    nonisolated static func usableCookie(in cookies: [HTTPCookie], now: Date = Date()) -> HTTPCookie? {
        cookies.first { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return cookie.name == "PHPSESSID" && ["pixiv.net", "www.pixiv.net"].contains(domain)
                && cookie.path == "/" && (cookie.expiresDate.map { $0 > now } ?? true) && validToken(cookie.value)
        }
    }

    nonisolated private static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && value.utf8.allSatisfy {
            $0 > 32 && $0 < 127 && ![UInt8(34), 44, 59, 92].contains($0)
        }
    }

    @discardableResult func refreshFromCookies() async -> Bool {
        let epoch = generation
        let cookies = await readCookies()
        guard epoch == generation, !Task.isCancelled else { return false }
        return await authenticate(cookies: cookies)
    }

    /// 登录窗口使用独立网页会话，只校验该窗口提供的 Cookie。
    @discardableResult func authenticate(cookies: [HTTPCookie]) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let cookie = Self.usableCookie(in: cookies) else {
            errorMessage = "尚未检测到有效的 Pixiv 登录，请在网页中完成登录。"
            return false
        }
        return await beginValidation(PixivCredential(phpsessid: cookie.value, userID: nil, userName: nil, updatedAt: Date())).value
    }

    func prepareForWebLogin() {
        cancelAuthentication()
        if !isLoggedIn { errorMessage = nil }
    }

    @discardableResult func checkLoginState() async -> Bool {
        if let validationTask { return await validationTask.value }
        guard let candidate = credential ?? savedCandidate else { return false }
        return await beginValidation(candidate).value
    }

    @discardableResult private func beginValidation(_ candidate: PixivCredential) -> Task<Bool, Never> {
        validationTask?.cancel()
        let epoch = UUID()
        generation = epoch
        isChecking = true
        errorMessage = nil
        let task = Task { [weak self] in
            guard let self else { return false }
            defer {
                if self.generation == epoch { self.isChecking = false; self.validationTask = nil }
            }
            return await self.validate(candidate, epoch: epoch)
        }
        validationTask = task
        return task
    }

    private struct Envelope: Decodable {
        let error: Bool
        let body: Body?
        struct Body: Decodable {
            let id: String?
            let name: String?
            let userData: Profile?
            struct Profile: Decodable { let id: String?; let name: String? }
            enum CodingKeys: CodingKey { case id, name, userData }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = (try? values.decode(String.self, forKey: .id)) ?? (try? values.decode(Int.self, forKey: .id)).map(String.init)
                name = try values.decodeIfPresent(String.self, forKey: .name)
                userData = try values.decodeIfPresent(Profile.self, forKey: .userData)
            }
        }
    }

    private func validate(_ candidate: PixivCredential, epoch: UUID) async -> Bool {
        guard Self.validToken(candidate.phpsessid) else { errorMessage = PixivSessionError.invalidResponse.localizedDescription; return false }
        var request = URLRequest(url: URL(string: "https://www.pixiv.net/ajax/user/extra")!)
        request.httpShouldHandleCookies = false
        request.setValue("https://www.pixiv.net/", forHTTPHeaderField: "Referer")
        request.setValue(SourceHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("PHPSESSID=\(candidate.phpsessid)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await requestLoader(request)
            guard epoch == generation, !Task.isCancelled else { return false }
            guard let http = response as? HTTPURLResponse, http.url?.host == "www.pixiv.net" else { throw PixivSessionError.invalidResponse }
            if http.statusCode == 401 { expire(epoch: epoch); return false }
            guard (200..<300).contains(http.statusCode) else { throw PixivSessionError.connection }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            if envelope.error { expire(epoch: epoch); return false }
            guard let body = envelope.body else { throw PixivSessionError.invalidResponse }
            var verified = candidate
            verified.userID = body.id ?? body.userData?.id ?? candidate.phpsessid.split(separator: "_").first.flatMap { part in
                part.allSatisfy(\.isNumber) ? String(part) : nil
            }
            verified.userName = body.name ?? body.userData?.name
            // 校验通过后才发布给界面和网络请求；钥匙串失败则明确为临时会话。
            credential = verified
            savedCandidate = verified
            vault.publish(verified)
            isPersistent = persist(verified)
            userID = verified.userID
            userName = verified.userName
            isLoggedIn = true
            return true
        } catch {
            guard epoch == generation, !Task.isCancelled else { return false }
            errorMessage = PixivSessionError.connection.localizedDescription
            return false
        }
    }

    private func persist(_ value: PixivCredential) -> Bool {
        do {
            try keychain.save(value)
            defaults.set(false, forKey: Self.signedOutKey)
            errorMessage = nil
            return true
        } catch {
            // 旧记录不能在重启后复活成另一个账号。
            defaults.set(true, forKey: Self.signedOutKey)
            errorMessage = "Pixiv 登录已验证，但无法保存到系统钥匙串。仅本次有效，重启后需重新登录。"
            return false
        }
    }

    @discardableResult func retryPersistence() -> Bool {
        guard let credential, isLoggedIn else { return false }
        isPersistent = persist(credential)
        return isPersistent
    }

    private func expire(epoch: UUID) {
        guard generation == epoch else { return }
        defaults.set(true, forKey: Self.signedOutKey)
        credential = nil; savedCandidate = nil; vault.publish(nil)
        isLoggedIn = false; isPersistent = false; userID = nil; userName = nil
        do { try keychain.remove(); errorMessage = PixivSessionError.expired.localizedDescription }
        catch { errorMessage = "Pixiv 会话已失效，钥匙串记录未能删除；已禁止自动恢复，请重新登录。" }
    }

    func cancelAuthentication() {
        guard isChecking else { return }
        generation = UUID(); validationTask?.cancel(); validationTask = nil; isChecking = false
    }

    func logout() async {
        generation = UUID()
        let epoch = generation
        validationTask?.cancel(); validationTask = nil; isChecking = false
        defaults.set(true, forKey: Self.signedOutKey)
        credential = nil; savedCandidate = nil; vault.publish(nil)
        isLoggedIn = false; isPersistent = false; userID = nil; userName = nil; errorMessage = nil
        do { try keychain.remove() }
        catch { errorMessage = "已退出 Pixiv，但未能删除钥匙串记录；该记录不会自动恢复。" }
        let cookies = await readCookies()
        for cookie in cookies {
            guard epoch == generation else { return }
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if domain == "pixiv.net" || domain.hasSuffix(".pixiv.net") { await deleteCookie(cookie) }
        }
    }
}
