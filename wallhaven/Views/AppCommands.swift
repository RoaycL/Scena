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

        CommandMenu("播放列表") {
            PlaylistCommands()
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

/// 播放列表菜单项（顶部菜单栏和状态栏共用）
struct PlaylistCommands: View {
    @ObservedObject private var manager = PlaylistManager.shared
    @Environment(\.openWindow) private var openWindow
    var showsManageShortcut = true

    var body: some View {
        if showsManageShortcut {
            Button("管理播放列表…") { openWindow(id: PlaylistsWindow.id) }
                .keyboardShortcut("p", modifiers: [.command, .option])
        } else {
            Button("管理播放列表…") { openWindow(id: PlaylistsWindow.id) }
        }

        if let active = manager.activePlaylist {
            Divider()
            Text("正在播放：\(active.name)")
            Button("下一张") { manager.next() }
            Button("上一张") { manager.previous() }
            Button("停止播放列表") { manager.stop() }
        }

        if !manager.playlists.isEmpty {
            Divider()
            ForEach(manager.playlists) { playlist in
                Button {
                    manager.play(playlist.id)
                } label: {
                    if manager.activeID == playlist.id {
                        Label(playlist.name, systemImage: "checkmark")
                    } else {
                        Text("播放「\(playlist.name)」")
                    }
                }
                .disabled(playlist.entries.isEmpty)
            }
        }
    }
}

/// 状态栏图标的菜单
struct StatusMenuContent: View {
    @ObservedObject var liveController: LiveWallpaperController
    @ObservedObject private var playlists = PlaylistManager.shared
    @EnvironmentObject private var viewModel: WallpaperViewModel
    @EnvironmentObject private var workshop: WorkshopViewModel
    @Environment(\.openWindow) private var openWindow
    private let volumeLevels = [0, 25, 50, 75, 100]

    var body: some View {
        Button("素材中心") { showMainWindow() }
        Menu("播放列表") { PlaylistCommands(showsManageShortcut: false) }
        Button("导入本地图片或视频…") {
            NSApp.activate()
            LocalMediaViewModel().importFiles()
            showMainWindow(tab: .local)
        }
        Button("添加工坊壁纸文件夹…") {
            NSApp.activate()
            workshop.addLibraryFolder()
            showMainWindow(tab: .workshop)
        }
        Divider()

        if let content = liveController.current {
            Text("正在播放：\(content.title)")
        }
        Menu("切换壁纸") {
            Button("上一张") { playlists.previous() }
                .disabled(playlists.activePlaylist == nil)
            Button("下一张") { playlists.next() }
                .disabled(playlists.activePlaylist == nil)
            Divider()
            Button("随机壁纸") {
                playlists.userDidApplyManually()
                viewModel.applyRandomWallpaper()
            }
            Button("从素材中心选择…") { showMainWindow() }
        }
        Button(liveController.isPaused || playlists.isPaused ? "恢复播放" : "暂停播放") {
            if liveController.isActive {
                liveController.togglePause()
            } else {
                playlists.setPlaybackPaused(!playlists.isPaused)
            }
        }
        .disabled(!liveController.isActive && playlists.activePlaylist == nil)
        Menu("音量调节") {
            ForEach(volumeLevels, id: \.self) { level in
                Button {
                    liveController.setVolume(Double(level) / 100)
                } label: {
                    if Int((liveController.volume * 100).rounded()) == level {
                        Label(level == 0 ? "静音" : "\(level)%", systemImage: "checkmark")
                    } else {
                        Text(level == 0 ? "静音" : "\(level)%")
                    }
                }
            }
        }
        Button("停止播放") {
            playlists.stop()
            liveController.stop()
        }
        .disabled(!liveController.isActive && playlists.activePlaylist == nil)
        Divider()

        Menu("下载任务（\(workshop.downloading.count) 个进行中）") {
            Button("管理下载…") {
                NSApp.activate()
                openWindow(id: DownloadsWindow.id)
            }
            Divider()
            Button("全部暂停") { workshop.pauseAllDownloads() }
                .disabled(workshop.downloading.isEmpty)
            Button("恢复已暂停任务") { workshop.resumeAllDownloads() }
                .disabled(!workshop.downloadJobs.contains { $0.state == .paused })
            Button("停止全部任务") { workshop.cancelAllDownloads() }
                .disabled(!workshop.downloadJobs.contains { [.queued, .downloading, .paused, .failed].contains($0.state) })
        }
        Button("同步 Steam 订阅") { workshop.syncSubscriptions(force: true) }
            .disabled(workshop.isSyncing)
        Divider()

        SettingsLink { Text("偏好设置…") }
            .keyboardShortcut(",")
        Divider()
        Button("退出 wallhaven") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showMainWindow(tab: MainTab? = nil) {
        MainWindow.opener = { openWindow(id: MainWindow.id) }
        MainWindow.show(tab: tab)
    }
}

enum MainWindow {
    static let id = "main"
    static let navigationNotification = Notification.Name("wallhaven.mainWindowNavigate")
    static var requestedTab: MainTab?

    /// SwiftUI 的 openWindow 只能在视图里拿到，主窗口出现时保存下来，供 Dock 图标重新打开窗口使用
    static var opener: (() -> Void)?

    static var existingWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(id) == true }
    }

    /// 已有主窗口就带到前台（包括最小化的），否则新建一个
    static func show(tab: MainTab? = nil) {
        requestedTab = tab
        NSApp.activate()
        if let window = existingWindow, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let opener {
            // 已关闭的窗口交给 SwiftUI 重新创建
            opener()
        } else {
            existingWindow?.makeKeyAndOrderFront(nil)
        }
        if tab != nil { NotificationCenter.default.post(name: navigationNotification, object: nil) }
    }
}
