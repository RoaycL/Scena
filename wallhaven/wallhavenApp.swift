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
        LiveWallpaperController.shared.restore()
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

        // 状态栏图标（可在设置中关闭）
        MenuBarExtra(isInserted: $showStatusItem) {
            StatusMenuContent(liveController: liveController)
                .environmentObject(viewModel)
        } label: {
            Image(systemName: statusIcon)
        }
    }

    private var statusIcon: String {
        guard liveController.isActive else { return "photo.on.rectangle.angled" }
        return liveController.isPaused ? "pause.rectangle" : "play.rectangle"
    }
}
