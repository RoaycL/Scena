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
        // 单元测试以 App 为宿主运行：不读取真实的 Pixiv 钥匙串，也不恢复用户的动态壁纸、播放列表、
        // 全局快捷键和自动转换，避免测试在用户桌面上开窗口或迁移、改写用户数据
        guard !AppRuntime.isRunningTests else { return }
        _ = PixivAccountSession.shared
        LiveWallpaperController.shared.restore()
        PlaylistManager.shared.restore()
        DockIcon.apply()
        GlobalHotKeys.shared.registerAll()
        AutoBakeScheduler.shared.activate()
        #if DEBUG
        // 调试：SCENA_DEBUG_BAKE=<工坊壁纸文件夹> 启动后直接烘焙这个壁纸
        if let path = ProcessInfo.processInfo.environment["SCENA_DEBUG_BAKE"],
           let item = WorkshopItem.load(from: URL(fileURLWithPath: path, isDirectory: true), computeSize: false) {
            WallpaperBaker.shared.bake(item)
        }
        #endif
        // 启动几秒后在后台检查 GitHub 更新（每天最多一次，可在设置中关闭）
        Task {
            try? await Task.sleep(for: .seconds(5))
            await UpdateManager.shared.checkAutomaticallyIfNeeded()
        }
    }

    private var isPreparingToQuit = false

    /// 定格画面最多等 3 秒；随后等待后台更新安装结束，不能提前退出复制过程。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isPreparingToQuit { return .terminateLater }
        let updates = UpdateManager.shared
        guard !updates.isInstalling else { return .terminateCancel }
        guard LiveWallpaperController.shared.isActive || updates.isReadyToInstall else { return .terminateNow }
        isPreparingToQuit = true
        Task {
            if LiveWallpaperController.shared.isActive {
                await withCheckedContinuation { continuation in
                    var finished = false
                    let finish = {
                        guard !finished else { return }
                        finished = true
                        continuation.resume()
                    }
                    Task {
                        await LiveWallpaperController.shared.freezeCurrentFrame()
                        finish()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish() }
                }
            }
            do {
                try await updates.installPendingUpdateBeforeQuit()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                isPreparingToQuit = false
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        PlaylistManager.shared.flushPendingSave()
        SteamCMDDownloader.shared.terminateAll()
        SteamContentDownloader.shared.cancelAll()
        UpdateManager.shared.cancelDownload()
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
    @StateObject private var viewModel = WallpaperViewModel(pixivAccount: AppRuntime.isRunningTests ? nil : .shared)
    @StateObject private var workshop = WorkshopViewModel()
    @StateObject private var liveController = LiveWallpaperController.shared
    @AppStorage(AppSettings.showStatusItemKey) private var showStatusItem = true

    init() {
        // 旧目录结构整理成 Scena/{Wallhaven, Wallpaper Engine, Imported}，要在其他组件读取路径之前完成
        StorageManager.shared.upgradeLayoutIfNeeded()
    }

    var body: some Scene {
        WindowGroup("Scena", id: MainWindow.id) {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(workshop)
                .scenaTheme()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            WallhavenCommands(liveController: liveController)
        }

        Settings {
            SettingsView()
                .environmentObject(viewModel)
                .environmentObject(workshop)
                .scenaTheme()
        }

        Window("播放列表", id: PlaylistsWindow.id) {
            PlaylistsView()
                .scenaTheme()
        }
        .defaultSize(width: 960, height: 680)

        Window("下载任务", id: DownloadsWindow.id) {
            WorkshopDownloadsView()
                .environmentObject(workshop)
                .scenaTheme()
        }
        .windowResizability(.contentSize)

        Window("登录 Steam", id: SteamLoginWindow.id) {
            SteamLoginView()
                .scenaTheme(transparentWindow: false)
        }
        .defaultSize(width: 520, height: 680)
        .windowResizability(.contentMinSize)

        Window("登录 Pixiv", id: PixivLoginWindow.id) {
            PixivLoginView()
                .scenaTheme(transparentWindow: false)
        }
        .defaultSize(width: 520, height: 680)
        .windowResizability(.contentMinSize)

        // 状态栏图标（可在设置中关闭）
        // 系统会反复把显示状态写回这个绑定；值不变也写会触发 UserDefaults 变更通知，
        // 让所有使用 @AppStorage 的界面不停重绘（打开的右键菜单会一直闪烁），所以只在真正变化时写入
        MenuBarExtra(isInserted: Binding(
            get: { showStatusItem },
            set: { if $0 != showStatusItem { showStatusItem = $0 } }
        )) {
            StatusMenuContent(liveController: liveController)
                .environmentObject(viewModel)
                .environmentObject(workshop)
        } label: {
            Image(nsImage: StatusBarIcon.image)
                .renderingMode(.template)
                .accessibilityLabel("Scena")
        }
    }


}
