import Foundation
import LocalAuthentication
import Security

/// 使用 macOS 登录钥匙串，兼容当前 GitHub 分发的 Developer ID/开发签名方式。
/// 不依赖需要专门 provisioning profile 的 Data Protection 访问组。
/// 仅保存持久令牌，短期 access token 与 Cookie 留在内存中。
final class SteamKeychain: SteamCredentialStoring {
    private let service: String

    init(service: String? = nil) {
        self.service = service ?? "\(Bundle.main.bundleIdentifier ?? "com.roayc.wallhaven").steam.auth.v1"
    }

    private var query: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "steam-account",
         kSecUseAuthenticationContext as String: context]
    }

    func load() throws -> SteamCredential? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SteamAuthenticationError.keychain(status) }
        guard let data = result as? Data, let credential = try? JSONDecoder().decode(SteamCredential.self, from: data) else {
            throw SteamAuthenticationError.protocolFailure
        }
        return credential
    }

    func save(_ credential: SteamCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Scena · Steam"
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
