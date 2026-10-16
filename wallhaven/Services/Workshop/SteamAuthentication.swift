import Foundation

nonisolated enum SteamAuthenticationError: LocalizedError, Equatable {
    case componentMissing, protocolFailure, connection, timeout, credentialsExpired, accountUnavailable
    case temporarilyUnavailable, accessDenied, keychain(Int32)

    init(code: String?) {
        self = switch code {
        case "credentialsExpired": .credentialsExpired
        case "accountUnavailable": .accountUnavailable
        case "temporarilyUnavailable": .temporarilyUnavailable
        case "accessDenied": .accessDenied
        case "timeout": .timeout
        case "protocol": .protocolFailure
        default: .connection
        }
    }

    var errorDescription: String? {
        switch self {
        case .componentMissing: "此构建未包含 Steam 认证组件，请使用网页登录或完整安装包。"
        case .protocolFailure: "Steam 认证组件返回了无效数据，请重新尝试。"
        case .connection: "无法连接 Steam，请检查网络后重试。"
        case .timeout: "Steam 登录等待超时，请刷新二维码或重试。"
        case .credentialsExpired: "Steam 授权已失效，请重新扫码登录。"
        case .accountUnavailable: "此 Steam 账号当前不可用，请在 Steam 中检查账号状态。"
        case .temporarilyUnavailable: "Steam 暂时无法处理登录，请稍后重试。"
        case .accessDenied: "Steam 拒绝了此次授权，请重新扫码确认。"
        case .keychain(let status): "无法访问登录钥匙串（\(status)），请解锁钥匙串后重试。"
        }
    }

    var invalidatesCredentials: Bool { self == .credentialsExpired || self == .accountUnavailable }
}

nonisolated struct SteamCredential: Codable, Equatable, Sendable {
    let accountName: String
    let steamID: String
    let refreshToken: String
}

nonisolated struct SteamAuthenticationResult: Codable, Sendable {
    let accountName: String
    let steamId: String
    let refreshToken: String
    let accessToken: String
    let expiresAt: Double

    var credential: SteamCredential { .init(accountName: accountName, steamID: steamId, refreshToken: refreshToken) }

    func validate(now: Date = Date()) throws {
        guard !accountName.isEmpty, accountName.utf8.count <= 128,
              !accountName.contains(where: \.isNewline),
              steamId.count == 17, steamId.allSatisfy(\.isNumber), UInt64(steamId) != nil,
              Self.validToken(refreshToken), Self.validToken(accessToken), expiresAt.isFinite,
              expiresAt > now.timeIntervalSince1970 + 30 else { throw SteamAuthenticationError.protocolFailure }
    }

    private static func validToken(_ token: String) -> Bool {
        (32...16384).contains(token.utf8.count)
            && token.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || [45, 46, 95].contains($0) }
    }
}

nonisolated struct SteamServiceRequest: Encodable, Sendable {
    let v = 1
    let id: String
    let method: String
    let loginId: UInt32
    let accountName: String?
    let refreshToken: String?

    init(id: UUID = UUID(), method: String, loginId: UInt32, credential: SteamCredential? = nil) {
        self.id = id.uuidString
        self.method = method
        self.loginId = loginId
        accountName = credential?.accountName
        refreshToken = credential?.refreshToken
    }
}

@MainActor protocol SteamAuthenticating {
    var isAvailable: Bool { get }
    func authenticate(_ request: SteamServiceRequest, onChallenge: @escaping @MainActor (URL) -> Void) async throws -> SteamAuthenticationResult
}

@MainActor protocol SteamCredentialStoring {
    func load() throws -> SteamCredential?
    func save(_ credential: SteamCredential) throws
    func remove() throws
}

nonisolated enum SteamLoginState: Equatable {
    case idle, connecting, qr(URL), restoring, signedIn, failed(String)

    var isBusy: Bool {
        switch self {
        case .connecting, .qr, .restoring: true
        default: false
        }
    }
}
