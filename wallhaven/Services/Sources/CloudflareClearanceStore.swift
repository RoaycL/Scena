import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// 已通过验证的 Cloudflare 凭据的持久化位置
nonisolated protocol ClearancePersistence: Sendable {
    func load() -> Data?
    func save(_ data: Data)
    func remove()
}

/// 默认存在系统钥匙串（凭据等同于访问网站的会话，不放明文偏好设置）。
/// 不弹出钥匙串授权框：签名不同的构建读不到时，当作没有凭据，重新验证即可
nonisolated struct KeychainClearancePersistence: ClearancePersistence {
    let service: String

    init(service: String = "\(Bundle.main.bundleIdentifier ?? "com.roayc.wallhaven").cloudflare.clearances.v2") {
        self.service = service
    }

    private var query: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: "clearances", kSecUseAuthenticationContext as String: context]
    }

    func load() -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func save(_ data: Data) {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Scena · Cloudflare 验证"
        SecItemAdd(item as CFDictionary, nil)
    }

    func remove() { SecItemDelete(query as CFDictionary) }
}

/// 测试用：存在指定的 UserDefaults
nonisolated struct DefaultsClearancePersistence: ClearancePersistence, @unchecked Sendable {
    let defaults: UserDefaults
    let key: String
    func load() -> Data? { defaults.data(forKey: key) }
    func save(_ data: Data) { defaults.set(data, forKey: key) }
    func remove() { defaults.removeObject(forKey: key) }
}

/// 保留服务器 Cookie 的原始作用域；保存只代表候选凭据可用，验证成功还需探测原请求。
nonisolated final class CloudflareClearanceStore: @unchecked Sendable {
    static let shared = CloudflareClearanceStore()
    private static let storageKey = "scena.cloudflare.clearances.v2"

    struct ScopedCookie: Codable, Sendable {
        let name: String
        let value: String
        let domain: String
        let hostOnly: Bool
        let path: String
        let secure: Bool
        let expiresAt: Date?

        init(_ cookie: HTTPCookie) {
            name = cookie.name; value = cookie.value
            domain = CloudflareClearanceStore.normalize(cookie.domain)
            hostOnly = !cookie.domain.hasPrefix(".")
            path = cookie.path; secure = cookie.isSecure; expiresAt = cookie.expiresDate
        }

        func matches(_ url: URL, now: Date = Date()) -> Bool {
            guard url.scheme == "https", let host = url.host?.lowercased(), !value.isEmpty,
                  value.utf8.allSatisfy({ $0 > 32 && $0 < 127 && ![UInt8(34), 44, 59, 92].contains($0) }),
                  expiresAt.map({ $0 > now }) ?? true,
                  host == domain || (!hostOnly && host.hasSuffix("." + domain)) else { return false }
            let requestPath = url.path.isEmpty ? "/" : url.path
            return requestPath == path || (requestPath.hasPrefix(path) && (path.hasSuffix("/") || requestPath.dropFirst(path.count).first == "/"))
        }
    }

    struct Candidate: Codable, Sendable {
        let verifiedHost: String
        let clearance: ScopedCookie
        let botManagement: ScopedCookie?
        let userAgent: String
        let updatedAt: Date

        func header(for url: URL, now: Date = Date()) -> String? {
            guard now.timeIntervalSince(updatedAt) < 86400, clearance.matches(url, now: now) else { return nil }
            var parts = ["cf_clearance=\(clearance.value)"]
            if let botManagement, botManagement.matches(url, now: now) { parts.append("__cf_bm=\(botManagement.value)") }
            return parts.joined(separator: "; ")
        }

        var fingerprint: String {
            // updatedAt 不参与去重，否则每次轮询都会重复发出探测请求。
            let value = [clearance.name, clearance.value, clearance.domain, clearance.path,
                         String(clearance.expiresAt?.timeIntervalSince1970 ?? 0), botManagement?.value ?? ""].joined(separator: "\n")
            return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    private let lock = NSLock()
    private var clearances: [String: Candidate] = [:]
    private let persistence: any ClearancePersistence

    /// 测试注入：存在指定的 UserDefaults
    convenience init(defaults: UserDefaults) {
        self.init(persistence: DefaultsClearancePersistence(defaults: defaults, key: Self.storageKey), legacyDefaults: nil)
    }

    /// legacyDefaults：1.0.31 及更早版本把凭据存在偏好设置里，迁移进钥匙串后删除
    init(persistence: any ClearancePersistence = KeychainClearancePersistence(), legacyDefaults: UserDefaults? = .standard) {
        self.persistence = persistence
        var data = persistence.load()
        if let legacyDefaults, let legacy = legacyDefaults.data(forKey: Self.storageKey) {
            if data == nil {
                persistence.save(legacy)
                data = legacy
            }
            legacyDefaults.removeObject(forKey: Self.storageKey)
        }
        if let data, let records = try? JSONDecoder().decode([String: Candidate].self, from: data) {
            clearances = records.filter { _, record in
                guard let url = URL(string: "https://\(record.verifiedHost)\(record.clearance.path)") else { return false }
                return record.header(for: url) != nil
            }
        }
    }

    static func candidate(from cookies: [HTTPCookie], for url: URL, now: Date = Date()) -> Candidate? {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return nil }
        let scoped = cookies.map(ScopedCookie.init).filter { $0.matches(url, now: now) }
        guard let cookie = scoped.filter({ $0.name == "cf_clearance" }).sorted(by: { $0.path.count > $1.path.count }).first else { return nil }
        return Candidate(verifiedHost: host, clearance: cookie, botManagement: scoped.first { $0.name == "__cf_bm" },
                         userAgent: SourceHTTP.userAgent, updatedAt: now)
    }

    @discardableResult func saveClearance(from cookies: [HTTPCookie], for host: String) -> Bool {
        guard let url = URL(string: "https://\(Self.normalize(host))/"), let candidate = Self.candidate(from: cookies, for: url) else { return false }
        return save(candidate, for: url)
    }

    @discardableResult func save(_ candidate: Candidate, for url: URL) -> Bool {
        guard candidate.header(for: url) != nil else { return false }
        lock.withLock {
            clearances[candidate.verifiedHost + candidate.clearance.path] = candidate
            persistLocked()
        }
        return true
    }

    func cookieHeader(for url: URL) -> String? {
        lock.withLock {
            clearances.values.sorted { $0.updatedAt > $1.updatedAt }.lazy.compactMap { $0.header(for: url) }.first
        }
    }
    func cookieHeader(for host: String) -> String? {
        URL(string: "https://\(Self.normalize(host))/").flatMap { cookieHeader(for: $0) }
    }
    func hasClearance(for host: String) -> Bool { cookieHeader(for: host) != nil }

    func clear(for host: String) {
        let target = Self.normalize(host)
        lock.withLock {
            clearances = clearances.filter { _, record in
                let cookie = record.clearance
                return !(target == cookie.domain || (!cookie.hostOnly && target.hasSuffix("." + cookie.domain)))
            }
            persistLocked()
        }
    }
    func clearAll() {
        lock.withLock { clearances.removeAll(); persistence.remove() }
    }
    private func persistLocked() {
        guard !clearances.isEmpty else { persistence.remove(); return }
        if let data = try? JSONEncoder().encode(clearances) { persistence.save(data) }
    }
    private static func normalize(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
    static func isMatchingDomain(_ cookieDomain: String, target: String) -> Bool {
        let domain = normalize(cookieDomain), host = normalize(target)
        return domain == host || (cookieDomain.hasPrefix(".") && host.hasSuffix("." + domain))
    }
}

/// 识别 Cloudflare 质询页。只看响应头和页面开头（质询页的标题、质询参数都在 <head> 里）：
/// 正常页面也可能嵌入 Turnstile 组件、引用 challenges.cloudflare.com 的脚本，不能据此当成质询页，
/// 否则每次加载都会弹出验证
nonisolated enum CloudflareChallengeDetector {
    static func isChallenge(_ data: Data, response: HTTPURLResponse? = nil) -> Bool {
        if response?.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge" { return true }
        let head = String(decoding: data.prefix(8192), as: UTF8.self).lowercased()
        return head.contains("<title>just a moment") || head.contains("_cf_chl_opt") || head.contains("cf-chl-")
    }
}
