//
//  WallpaperManager.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import AppKit

struct WallpaperManager {
    static func applyWallpaper(from fileURL: URL) throws {
        guard let screen = NSScreen.main else {
            throw WallperError.wallpaper("未找到活动屏幕。")
        }
        try NSWorkspace.shared.setDesktopImageURL(fileURL, for: screen, options: [:])
    }
}
