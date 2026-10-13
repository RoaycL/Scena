//
//  AppCommands.swift
//  wallhaven
//
//  macOS 原生菜单：顶部菜单栏命令 + 状态栏图标菜单
//

import AppKit
import SwiftUI

/// 当前窗口提供给菜单栏的操作（通过 FocusedValue 传递，菜单项随选中项自动启用 / 禁用）
struct GalleryCommandActions {
    var currentTab: MainTab
    var hasSelection: Bool
    var canDownload: Bool
    var canFavorite: Bool
    var isFavorite: Bool
    var canOpenInBrowser: Bool
    var hasSearch: Bool
    var isChromeHidden: Bool

    let apply: () -> Void
    let download: () -> Void
    let toggleFavorite: () -> Void
    let move: (Int) -> Void
    let toggleChrome: () -> Void
    let switchTab: (MainTab) -> Void
    let focusSearch: () -> Void
    let openInBrowser: () -> Void
    let importLocal: () -> Void
    let addWorkshopFolder: () -> Void
}

extension FocusedValues {
    @Entry var galleryActions: GalleryCommandActions?
}

struct WallhavenCommands: Commands {
    @FocusedValue(\.galleryActions) private var actions
    @ObservedObject var liveController: LiveWallpaperController

    var body: some Commands {
        // 文件
        CommandGroup(replacing: .newItem) {
            Button("导入图片或视频…") { actions?.importLocal() }
                .keyboardShortcut("o")
                .disabled(actions == nil)
            Button("添加 Wallpaper Engine 文件夹…") { actions?.addWorkshopFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }

        // 显示
        CommandGroup(before: .toolbar) {
            ForEach(Array(MainTab.allCases.enumerated()), id: \.element) { index, tab in
                Button(tab.rawValue) { actions?.switchTab(tab) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                    .disabled(actions == nil)
            }
            Divider()
            Button(actions?.isChromeHidden == true ? "显示界面" : "隐藏界面") { actions?.toggleChrome() }
                .keyboardShortcut("\\")
                .disabled(actions == nil)
            Button("搜索") { actions?.focusSearch() }
                .keyboardShortcut("f")
                .disabled(actions?.hasSearch != true)
            Divider()
        }

        CommandMenu("壁纸") {
            Button("设为壁纸") { actions?.apply() }
                .keyboardShortcut(.return)
                .disabled(actions?.hasSelection != true)
            Button("下载") { actions?.download() }
                .keyboardShortcut("d")
                .disabled(actions?.canDownload != true)
            Button(actions?.isFavorite == true ? "取消收藏" : "收藏") { actions?.toggleFavorite() }
                .keyboardShortcut("l")
                .disabled(actions?.canFavorite != true)
            Divider()
            Button("上一张") { actions?.move(-1) }
                .keyboardShortcut(.leftArrow)
                .disabled(actions?.hasSelection != true)
            Button("下一张") { actions?.move(1) }
                .keyboardShortcut(.rightArrow)
                .disabled(actions?.hasSelection != true)
            Divider()
            Button("在浏览器中打开") { actions?.openInBrowser() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(actions?.canOpenInBrowser != true)
        }

        CommandMenu("动态壁纸") {
            if let content = liveController.current {
                Text(content.title)
                Divider()
            }
            Button(liveController.isPaused ? "继续播放" : "暂停") { liveController.togglePause() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!liveController.isActive)
            Button("停止动态壁纸") { liveController.stop() }
                .disabled(!liveController.isActive)
        }
    }
}

/// 状态栏图标的菜单
struct StatusMenuContent: View {
    @ObservedObject var liveController: LiveWallpaperController
    @EnvironmentObject private var viewModel: WallpaperViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let content = liveController.current {
            Text("动态壁纸：\(content.title)")
            Button(liveController.isPaused ? "继续播放" : "暂停") { liveController.togglePause() }
            Button("停止动态壁纸") { liveController.stop() }
            Divider()
        }

        Button("随机换一张壁纸") { viewModel.applyRandomWallpaper() }

        Divider()

        Button("打开 wallhaven") { showMainWindow() }
        SettingsLink { Text("设置…") }
            .keyboardShortcut(",")

        Divider()

        Button("退出 wallhaven") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// 已有主窗口就带到前台，否则新建
    private func showMainWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(MainWindow.id) == true }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: MainWindow.id)
        }
    }
}

enum MainWindow {
    static let id = "main"
}
