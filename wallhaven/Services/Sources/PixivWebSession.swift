import Foundation
import WebKit

/// 与其他图源隔离的持久网页资料，保留 Pixiv 的「信任此浏览器」状态。
/// 不使用 Safari 的资料，也不把网页登录中的临时 Cookie 发布给网络层。
@MainActor enum PixivWebSession {
    static let dataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "2C1B1271-3EE7-4D76-A918-7E8203A39F65")!)
}

nonisolated enum PixivLoginNavigation {
    /// accounts.pixiv.net 上的密码、验证码和双重认证均属于登录中间步骤。
    /// 只有主页面完成导航后，才能尝试确认是否已经登录。
    static func canInspectCookies(at url: URL?, isLoading: Bool) -> Bool {
        guard !isLoading, let url, url.scheme == "https", url.host?.lowercased() == "www.pixiv.net",
              url.user == nil, url.password == nil else { return false }
        let path = url.path.lowercased()
        return !["/login", "/signup", "/auth", "/ajax/"].contains(where: path.hasPrefix)
    }
}
