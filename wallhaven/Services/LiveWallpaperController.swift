//
//  LiveWallpaperController.swift
//  wallhaven
//

import AppKit
import AVFoundation
import Combine
import CryptoKit

/// 当前桌面动态壁纸的内容（持久化到 UserDefaults，下次启动恢复）
nonisolated struct LiveContent: Codable, Equatable {
    enum Kind: String, Codable {
        case video, workshop
    }

    let kind: Kind
    /// 视频文件，或工坊壁纸文件夹
    let path: String
    let title: String

    var url: URL { URL(fileURLWithPath: path) }
}

/// 动态壁纸：在每块屏幕的桌面层级放一个无边框窗口播放内容
/// （位于系统壁纸之上、桌面图标之下，不接收鼠标事件）
final class LiveWallpaperController: ObservableObject {
    static let shared = LiveWallpaperController()

    @Published private(set) var current: LiveContent?
    @Published private(set) var isPaused = false
    @Published private(set) var volume = min(1, max(0, UserDefaults.standard.double(forKey: "liveWallpaper.volume")))

    func setVolume(_ value: Double) {
        volume = min(1, max(0, value))
        UserDefaults.standard.set(volume, forKey: "liveWallpaper.volume")
        for (window, player) in zip(windows, players) {
            player.setVolume(window.screen == NSScreen.screens.first ? volume : 0)
        }
    }

    var isActive: Bool { current != nil }
    /// 视频文件或工坊文件夹的地址
    var currentURL: URL? { current?.url }

    private let storageKey = "liveWallpaper.content"
    private let legacyStorageKey = "liveWallpaper.path"
    private var windows: [NSWindow] = []
    private var players: [LivePlaybackView] = []
    private var observers: [NSObjectProtocol] = []
    private var mouseMonitors: [Any] = []
    /// 每次重建窗口递增，用于丢弃过期的回调
    private var generation = 0
    /// 系统原因（锁屏、睡眠）导致的暂停，与用户手动暂停分开记录
    private var isSystemSuspended = false

    private init() {
        observeSystemEvents()
    }

    /// App 启动时恢复上次的动态壁纸
    func restore() {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: legacyStorageKey) {
            defaults.removeObject(forKey: legacyStorageKey)
            try? start(video: URL(fileURLWithPath: path))
            return
        }
        guard let data = defaults.data(forKey: storageKey),
              let content = try? JSONDecoder().decode(LiveContent.self, from: data) else { return }
        guard FileManager.default.fileExists(atPath: content.path) else {
            // 外接盘没连接时保留设置，重新连接后会自动恢复；文件确实被删除才清除
            if StorageManager.isReachable(content.url) { defaults.removeObject(forKey: storageKey) }
            return
        }
        try? start(content)
    }

    func start(video url: URL) throws {
        try start(LiveContent(kind: .video, path: url.path, title: url.deletingPathExtension().lastPathComponent))
    }

    func start(workshop item: WorkshopItem) throws {
        guard let folder = item.localFolder else { throw WallperError.wallpaper("壁纸尚未下载。") }
        guard item.type.isPlayable else { throw WallperError.wallpaper("「应用」类型的壁纸是 Windows 程序，无法在 macOS 上运行。") }
        try start(LiveContent(kind: .workshop, path: folder.path, title: item.title))
    }

    private func start(_ content: LiveContent) throws {
        guard FileManager.default.fileExists(atPath: content.path) else {
            throw WallperError.wallpaper("壁纸文件不存在。")
        }
        current = content
        isPaused = false
        if let data = try? JSONEncoder().encode(content) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        rebuildWindows()
        setStaticPoster(for: content)
    }

    /// 存储位置迁移后更新路径并重新播放（播放器还指向旧文件）
    func remapPath(from oldPrefix: String, to newPrefix: String) {
        guard let content = current, content.path == oldPrefix || content.path.hasPrefix(oldPrefix + "/") else { return }
        let newPath = newPrefix + content.path.dropFirst(oldPrefix.count)
        try? start(LiveContent(kind: content.kind, path: newPath, title: content.title))
    }

    func stop() {
        tearDownWindows()
        current = nil
        isPaused = false
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    func togglePause() {
        isPaused.toggle()
        PlaylistManager.shared.setPlaybackPaused(isPaused)
        updatePlayback()
    }

    // MARK: - Windows

    private func makePlayer(for content: LiveContent) -> LivePlaybackView? {
        switch content.kind {
        case .video:
            return LoopingVideoNSView(url: content.url)
        case .workshop:
            guard let item = WorkshopItem.load(from: content.url) else { return nil }
            // 视频类工坊壁纸优先用 AVFoundation 播放，更省电
            if let videoURL = item.nativeVideoURL {
                return LoopingVideoNSView(url: videoURL)
            }
            let player = WorkshopPlayerNSView(item: item, fps: 30)
            player.onStateChange = { state in
                if case .failed(let message) = state {
                    ToastCenter.shared.show("动态壁纸渲染失败：\(message)", style: .error)
                }
            }
            return player
        }
    }

    /// 新窗口先以透明状态创建，播放器出第一帧后淡入，再移除旧窗口：切换时不会黑屏
    private func rebuildWindows() {
        generation += 1
        let currentGeneration = generation
        let oldWindows = windows
        let oldPlayers = players
        removeMouseTracking()
        windows = []
        players = []

        guard let content = current else {
            fadeOut(oldWindows, oldPlayers)
            return
        }

        for screen in NSScreen.screens {
            guard let player = makePlayer(for: content) else { continue }
            // 多屏只让主屏输出声音，避免重复播放与叠加音量。
            player.setVolume(screen == NSScreen.screens.first ? volume : 0)
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            window.ignoresMouseEvents = true
            window.isOpaque = false
            window.hasShadow = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            // ⌘H 隐藏 App 时壁纸窗口不能跟着消失
            window.canHide = false
            window.alphaValue = 0
            window.contentView = player
            window.setFrame(screen.frame, display: true)
            // 同一层级里后 orderFront 的在上面，盖住旧窗口
            window.orderFront(nil)

            windows.append(window)
            players.append(player)
        }

        var pending = windows.count
        let finish = { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.retire(oldWindows, oldPlayers)
        }
        for (window, player) in zip(windows, players) {
            player.whenReady { [weak self, weak window] in
                guard let self, self.generation == currentGeneration, let window else { return }
                self.reveal(window)
                pending -= 1
                if pending == 0 { finish() }
            }
        }
        // 兜底：播放器迟迟没有就绪时也要显示出来，不能一直停留在旧壁纸上
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.windows.filter { $0.alphaValue < 1 }.forEach(self.reveal)
            finish()
        }

        if players.contains(where: { $0 is WorkshopPlayerNSView }) {
            installMouseTracking()
        }
        updatePlayback()
    }

    private func reveal(_ window: NSWindow) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            window.animator().alphaValue = 1
        }
    }

    /// 新窗口淡入完成后再移除旧窗口
    private func retire(_ oldWindows: [NSWindow], _ oldPlayers: [LivePlaybackView]) {
        guard !oldWindows.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            oldPlayers.forEach { $0.stop() }
            oldWindows.forEach { $0.orderOut(nil) }
        }
    }

    /// 停止动态壁纸时淡出，露出下面的静态壁纸
    private func fadeOut(_ oldWindows: [NSWindow], _ oldPlayers: [LivePlaybackView]) {
        guard !oldWindows.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            oldWindows.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: {
            MainActor.assumeIsolated {
                oldPlayers.forEach { $0.stop() }
                oldWindows.forEach { $0.orderOut(nil) }
            }
        }
    }

    private func tearDownWindows() {
        generation += 1
        removeMouseTracking()
        fadeOut(windows, players)
        players.removeAll()
        windows.removeAll()
    }

    private func removeMouseTracking() {
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors.removeAll()
    }

    private func updatePlayback() {
        let shouldPlay = !isPaused && !isSystemSuspended
        players.forEach { shouldPlay ? $0.play() : $0.pause() }
    }

    /// 桌面窗口不接收鼠标事件，把全局鼠标位置推给场景壁纸（视差 / 鼠标交互效果）
    private func installMouseTracking() {
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.pushMouseLocation() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { event in
            handler(event)
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func pushMouseLocation() {
        let location = NSEvent.mouseLocation
        for (window, player) in zip(windows, players) {
            guard let player = player as? WorkshopPlayerNSView, window.frame.contains(location) else { continue }
            let frame = window.frame
            player.pushPointer(
                u: (location.x - frame.minX) / frame.width,
                v: 1 - (location.y - frame.minY) / frame.height
            )
        }
    }

    // MARK: - Static poster

    /// 把封面设为系统静态壁纸：App 退出后桌面仍保持一致的画面
    private func setStaticPoster(for content: LiveContent) {
        Task {
            guard let posterURL = try? await Self.makePoster(for: content) else { return }
            // 期间可能已切换到别的壁纸
            guard self.current == content else { return }
            for screen in NSScreen.screens {
                try? NSWorkspace.shared.setDesktopImageURL(posterURL, for: screen, options: [:])
            }
        }
    }

    nonisolated private static func makePoster(for content: LiveContent) async throws -> URL {
        let fm = FileManager.default
        let folder = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("wallhaven/LivePosters", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        // 每个内容一个独立文件名，系统才会刷新壁纸
        let hash = SHA256.hash(data: Data(content.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let posterURL = folder.appendingPathComponent("poster-\(hash).png")
        if fm.fileExists(atPath: posterURL.path) { return posterURL }

        let cgImage: CGImage
        switch content.kind {
        case .video:
            cgImage = try await firstFrame(of: content.url)
        case .workshop:
            let item = WorkshopItem.load(from: content.url)
            if let videoURL = item?.nativeVideoURL {
                cgImage = try await firstFrame(of: videoURL)
            } else if let preview = item?.previewURL,
                      let image = NSImage(contentsOf: preview),
                      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                cgImage = cg
            } else {
                throw WallperError.wallpaper("没有可用的封面。")
            }
        }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw WallperError.wallpaper("无法生成封面。")
        }
        try data.write(to: posterURL, options: .atomic)
        return posterURL
    }

    nonisolated private static func firstFrame(of url: URL) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        return try await generator.image(at: .zero).image
    }

    // MARK: - System events

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.rebuildWindows()
            }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        let suspendNames: [Notification.Name] = [
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.willSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ]
        let resumeNames: [Notification.Name] = [
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        for name in suspendNames {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isSystemSuspended = true
                    self?.updatePlayback()
                }
            })
        }
        for name in resumeNames {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isSystemSuspended = false
                    self?.updatePlayback()
                }
            })
        }
    }
}
