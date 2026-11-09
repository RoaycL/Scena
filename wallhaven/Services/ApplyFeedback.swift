//
//  ApplyFeedback.swift
//  wallhaven
//

import AppKit
import Combine

/// 「设为壁纸」按钮的状态来源：正在设置、刚刚设置成功（短暂显示对勾）。
/// 反馈放在按钮上，而不是右上角的提示条
final class ApplyFeedback: ObservableObject {
    static let shared = ApplyFeedback()

    @Published private(set) var applying: Set<String> = []
    @Published private(set) var justApplied: String?
    private var clearTask: Task<Void, Never>?

    func begin(_ id: String) {
        applying.insert(id)
    }

    func finish(_ id: String, success: Bool) {
        applying.remove(id)
        guard success else { return }
        justApplied = id
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, self?.justApplied == id else { return }
            self?.justApplied = nil
        }
    }
}

extension GalleryItem {
    /// 这张是否就是当前桌面壁纸：动态壁纸看正在播放的内容，静态图看主屏幕的桌面图片
    var isOnDesktop: Bool {
        let live = LiveWallpaperController.shared.currentURL?.standardizedFileURL
        switch origin {
        case .workshop(let item):
            return live != nil && item.localFolder?.standardizedFileURL == live
        case .local(let item) where item.isVideo:
            return live != nil && item.url.standardizedFileURL == live
        case .local(let item):
            return live == nil && Self.isDesktopImage(item.url)
        case .remote(let wallpaper) where wallpaper.isVideo:
            return live != nil && wallpaper.localFileURL?.standardizedFileURL == live
        case .remote(let wallpaper):
            guard live == nil, let url = wallpaper.localFileURL else { return false }
            return Self.isDesktopImage(url)
        }
    }

    private static func isDesktopImage(_ url: URL) -> Bool {
        guard let desktop = DesktopImageCache.mainScreenImage() else { return false }
        return desktop.standardizedFileURL.path == url.standardizedFileURL.path
    }
}

/// 查询系统桌面图片每次约 1.5 毫秒，而按钮每次重绘都要判断一次；短时间内复用结果
@MainActor
enum DesktopImageCache {
    private static var cached: (time: TimeInterval, url: URL?)?

    static func mainScreenImage() -> URL? {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached, now - cached.time < 1 { return cached.url }
        let url = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        cached = (now, url)
        return url
    }

    /// 本 App 刚设置了桌面图片
    static func invalidate() { cached = nil }
}
