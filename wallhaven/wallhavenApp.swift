//
//  wallhavenApp.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 不需要窗口标签页，去掉「显示」菜单里的 Show Tab Bar
        NSWindow.allowsAutomaticWindowTabbing = false
        StorageManager.configureImageCache()
        LiveWallpaperController.shared.restore()
        PlaylistManager.shared.restore()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SteamCMDDownloader.shared.terminateAll()
    }

    /// 点击 Dock 图标：桌面上的动态壁纸窗口也算「可见窗口」，系统会因此不重新打开主窗口，
    /// 所以这里只看主窗口本身是否可见
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if MainWindow.existingWindow?.isVisible != true {
            MainWindow.show()
            return false
        }
        return true
    }

    // 关闭主窗口后继续运行，动态壁纸不中断
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

enum AppSettings {
    static let showStatusItemKey = "showStatusItem"
}

@main
struct wallhavenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = WallpaperViewModel()
    @StateObject private var workshop = WorkshopViewModel()
    @StateObject private var liveController = LiveWallpaperController.shared
    @AppStorage(AppSettings.showStatusItemKey) private var showStatusItem = true

    var body: some Scene {
        WindowGroup(id: MainWindow.id) {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(workshop)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            WallhavenCommands(liveController: liveController)
        }

        Settings {
            SettingsView()
                .environmentObject(viewModel)
                .environmentObject(workshop)
        }

        Window("播放列表", id: PlaylistsWindow.id) {
            PlaylistsView()
        }
        .defaultSize(width: 760, height: 520)

        Window("下载任务", id: DownloadsWindow.id) {
            WorkshopDownloadsView()
                .environmentObject(workshop)
        }
        .windowResizability(.contentSize)

        Window("登录 Steam", id: SteamLoginWindow.id) {
            SteamLoginView()
        }
        .defaultSize(width: 520, height: 680)
        .windowResizability(.contentMinSize)

        // 状态栏图标（可在设置中关闭）
        MenuBarExtra(isInserted: $showStatusItem) {
            StatusMenuContent(liveController: liveController)
                .environmentObject(viewModel)
                .environmentObject(workshop)
        } label: {
            Image(systemName: statusIcon)
        }
    }

    private var statusIcon: String {
        guard liveController.isActive else { return "photo.on.rectangle.angled" }
        return liveController.isPaused ? "pause.rectangle" : "play.rectangle"
    }
}
