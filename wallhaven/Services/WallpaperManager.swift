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
            try LiveWallpaperController.shared.start(video: fileURL)
            return
        }

        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            throw WallperError.wallpaper("未找到活动屏幕。")
        }
        // 先换好静态壁纸，再淡出上层的动态壁纸窗口，避免中间露出旧壁纸或黑屏
        for screen in screens {
            try NSWorkspace.shared.setDesktopImageURL(fileURL, for: screen, options: [:])
        }
        LiveWallpaperController.shared.stop()
    }
}
