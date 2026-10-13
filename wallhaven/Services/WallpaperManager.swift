//
//  WallpaperManager.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import AppKit

enum WallpaperManager {
    /// 图片 → 设为系统壁纸（所有显示器）；视频 → 启动动态壁纸
    static func applyWallpaper(from fileURL: URL) throws {
        if MediaType.isVideo(fileURL) {
            try LiveWallpaperController.shared.start(fileURL)
            return
        }

        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            throw WallperError.wallpaper("未找到活动屏幕。")
        }
        // 设置静态壁纸时关闭动态壁纸，否则会被视频窗口遮住
        LiveWallpaperController.shared.stop()
        // 应用到所有显示器
        for screen in screens {
            try NSWorkspace.shared.setDesktopImageURL(fileURL, for: screen, options: [:])
        }
    }
}
