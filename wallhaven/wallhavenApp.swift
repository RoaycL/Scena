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
        LiveWallpaperController.shared.restore()
    }

    // 关闭主窗口后继续运行，动态壁纸不中断
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct wallhavenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = WallpaperViewModel()
    @StateObject private var workshop = WorkshopViewModel()
    @StateObject private var liveController = LiveWallpaperController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(workshop)
        }
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environmentObject(viewModel)
                .environmentObject(workshop)
        }

        // 动态壁纸播放时在菜单栏显示控制项
        MenuBarExtra(isInserted: .constant(liveController.isActive)) {
            if let content = liveController.current {
                Text(content.title)
                Divider()
            }
            Button(liveController.isPaused ? "继续播放" : "暂停") { liveController.togglePause() }
            Button("停止动态壁纸") { liveController.stop() }
            Divider()
            Button("打开 wallhaven") {
                NSApp.activate()
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            }
            Button("退出") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: liveController.isPaused ? "pause.rectangle" : "play.rectangle")
        }
    }
}
