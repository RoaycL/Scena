//
//  WallpaperManager.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import AppKit

struct WallpaperManager {
    static func applyWallpaper(from fileURL: URL) throws {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            throw WallperError.wallpaper("未找到活动屏幕。")
        }
        // 应用到所有显示器
        for screen in screens {
            try NSWorkspace.shared.setDesktopImageURL(fileURL, for: screen, options: [:])
        }
    }
}
