//
//  LiveWallpaperController.swift
//  wallhaven
//

import AppKit
import AVFoundation
import ImageIO
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
        let wasSilent = volume <= 0
        volume = min(1, max(0, value))
        // 静音的视频不解码音轨；从静音调到有声（或反过来）时重建播放器
        if wasSilent != (volume <= 0), players.contains(where: { $0 is LoopingVideoNSView }) {
            UserDefaults.standard.set(volume, forKey: "liveWallpaper.volume")
            rebuildWindows()
            return
        }
        UserDefaults.standard.set(volume, forKey: "liveWallpaper.volume")
        for (window, player) in zip(windows, players) {
            player.setVolume(window.screen == NSScreen.screens.first ? volume : 0)
        }
    }

    /// 场景 / 网页类工坊壁纸的渲染帧率（视频按原始帧率播放）
    @Published private(set) var frameRate: Int = {
        let saved = UserDefaults.standard.integer(forKey: "liveWallpaper.fps")
        return [15, 30, 60].contains(saved) ? saved : 30
    }()

    func setFrameRate(_ fps: Int) {
        guard [15, 30, 60].contains(fps), fps != frameRate else { return }
        frameRate = fps
        UserDefaults.standard.set(fps, forKey: "liveWallpaper.fps")
        // 只有 WebGL 渲染的壁纸受帧率影响，重新创建播放器使其生效
        if players.contains(where: { $0 is WorkshopPlayerNSView }) { rebuildWindows() }
    }

    var isActive: Bool { current != nil }
    /// 视频文件或工坊文件夹的地址
    var currentURL: URL? { current?.url }

    private let storageKey = "liveWallpaper.content"
    private let legacyStorageKey = "liveWallpaper.path"
    private final class Surface {
        let window: NSWindow
        let player: LivePlaybackView
        private var isClosed = false

        init(window: NSWindow, player: LivePlaybackView) {
            self.window = window
            self.player = player
        }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            player.stop()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
    }

    private let surfaces = WallpaperWindowLifecycle<Surface>()
    private var windows: [NSWindow] { surfaces.active.map(\.window) }
    private var players: [LivePlaybackView] { surfaces.active.map(\.player) }
    private var observers: [NSObjectProtocol] = []
    private var mouseMonitors: [Any] = []
    /// 系统原因（锁屏、睡眠）导致的暂停，与用户手动暂停分开记录
    private var isSystemSuspended = false
    /// 设置里的自动暂停条件（其他 App 在使用、全屏、电池、不活跃）
    @Published private(set) var autoPauseReasons: Set<AutoPauseMonitor.Reason> = []
    private let autoPause = AutoPauseMonitor()
    /// 影响窗口布局的设置，变化时重建窗口
    private var layoutSignature = LiveWallpaperController.currentLayoutSignature

    private init() {
        observeSystemEvents()
        autoPause.onChange = { [weak self] in
            guard let self else { return }
            self.autoPauseReasons = self.autoPause.reasons
            self.updatePlayback()
        }
        autoPause.start()
    }

    private static var currentLayoutSignature: String {
        [
            String(DesktopSettings.bool(DesktopSettings.coverDesktopIcons, default: false)),
            String(DesktopSettings.bool(DesktopSettings.keepAspectRatio, default: false)),
            DesktopSettings.backgroundNSColor.hexString,
            DesktopSettings.disabledDisplayIDs.sorted().joined(separator: ","),
        ].joined(separator: "|")
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
        let matches = { (path: String) in path == oldPrefix || path.hasPrefix(oldPrefix + "/") }
        if let content = current {
            guard matches(content.path) else { return }
            let newPath = newPrefix + content.path.dropFirst(oldPrefix.count)
            try? start(LiveContent(kind: content.kind, path: newPath, title: content.title))
            return
        }
        // 还没开始播放（App 启动阶段）：直接改保存的设置，稍后 restore() 会用新路径
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode(LiveContent.self, from: data),
              matches(saved.path) else { return }
        let updated = LiveContent(kind: saved.kind, path: newPrefix + saved.path.dropFirst(oldPrefix.count), title: saved.title)
        if let encoded = try? JSONEncoder().encode(updated) { defaults.set(encoded, forKey: storageKey) }
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

    private func makePlayer(for content: LiveContent, playsSound: Bool) -> LivePlaybackView? {
        switch content.kind {
        case .video:
            return LoopingVideoNSView(url: content.url, includeAudio: playsSound)
        case .workshop:
            guard let item = WorkshopItem.load(from: content.url) else { return nil }
            // 视频类工坊壁纸优先用 AVFoundation 播放，更省电
            if let videoURL = item.nativeVideoURL {
                return LoopingVideoNSView(url: videoURL, includeAudio: playsSound)
            }
            let player = WorkshopPlayerNSView(item: item, fps: frameRate)
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
        let currentGeneration = surfaces.beginReplacement()
        revealedWindows.removeAll()
        removeMouseTracking()

        guard let content = current else {
            fadeOut(surfaces.removeAll())
            return
        }

        let disabled = DesktopSettings.disabledDisplayIDs
        // 盖住桌面图标：窗口放到图标层之上（仍然不接收鼠标事件）
        let level = DesktopSettings.bool(DesktopSettings.coverDesktopIcons, default: false)
            ? Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
            : Int(CGWindowLevelForKey(.desktopWindow))
        let keepAspect = DesktopSettings.bool(DesktopSettings.keepAspectRatio, default: false)
        let background = DesktopSettings.backgroundNSColor
        for screen in NSScreen.screens where !disabled.contains(screen.displayUUID) {
            // 多屏只让主屏输出声音；音量为 0 时视频不解码音轨
            let playsSound = screen == NSScreen.screens.first && volume > 0
            guard let player = makePlayer(for: content, playsSound: playsSound) else { continue }
            (player as? LoopingVideoNSView)?.setFit(keepAspectRatio: keepAspect, background: background)
            // 多屏只让主屏输出声音，避免重复播放与叠加音量。
            player.setVolume(screen == NSScreen.screens.first ? volume : 0)
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: level)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            window.ignoresMouseEvents = true
            window.isOpaque = false
            window.hasShadow = false
            window.animationBehavior = .none
            window.isRestorable = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            // ⌘H 隐藏 App 时壁纸窗口不能跟着消失
            window.canHide = false
            window.alphaValue = 0
            player.frame = CGRect(origin: .zero, size: screen.frame.size)
            player.autoresizingMask = [.width, .height]
            window.contentView = player
            window.setFrame(screen.frame, display: true)
            player.layoutSubtreeIfNeeded()
            // 同一层级里后 orderFront 的在上面，盖住旧窗口
            window.orderFront(nil)

            surfaces.append(Surface(window: window, player: player))
        }

        guard !surfaces.active.isEmpty else {
            fadeOut(surfaces.removeAll())
            updatePlayback()
            return
        }
        var pending = windows.count
        let finish = { [weak self] in
            guard let self, self.surfaces.generation == currentGeneration else { return }
            self.retire()
        }
        for surface in surfaces.active {
            surface.player.whenReady { [weak self, weak surface] in
                guard let self, let surface,
                      self.surfaces.isCurrent(surface, generation: currentGeneration) else { return }
                self.reveal(surface, generation: currentGeneration)
                pending -= 1
                if pending == 0 { finish() }
            }
        }
        // 兜底：播放器迟迟没有就绪时也要显示出来，不能一直停留在旧壁纸上
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.surfaces.generation == currentGeneration else { return }
            for surface in self.surfaces.active where surface.window.alphaValue < 1 {
                self.reveal(surface, generation: currentGeneration)
            }
            finish()
        }

        if players.contains(where: { $0 is WorkshopPlayerNSView }) {
            installMouseTracking()
        }
        updatePlayback()
    }

    private func reveal(_ surface: Surface, generation: Int) {
        guard surfaces.isCurrent(surface, generation: generation) else { return }
        let window = surface.window
        window.contentView?.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            window.animator().alphaValue = 1
        } completionHandler: { [weak self, weak surface] in
            MainActor.assumeIsolated {
                guard let self, let surface,
                      self.surfaces.isCurrent(surface, generation: generation) else { return }
                self.revealedWindows.insert(ObjectIdentifier(surface.window))
                self.updatePlayback()
            }
        }
    }

    /// 已淡入完成的窗口：只有这些窗口才按遮挡状态暂停（淡入前的透明窗口会被系统当成不可见）
    private var revealedWindows: Set<ObjectIdentifier> = []

    /// 桌面被其他窗口完全挡住（最大化、全屏、铺满的窗口）时，这块屏幕上的壁纸看不见，暂停渲染
    private func isOccluded(_ window: NSWindow) -> Bool {
        DesktopSettings.bool(DesktopSettings.pauseWhenOccluded, default: true)
            && revealedWindows.contains(ObjectIdentifier(window)) && !window.occlusionState.contains(.visible)
    }

    /// 新窗口淡入完成后再移除旧窗口
    private func retire() {
        let oldSurfaces = surfaces.retiring
        guard !oldSurfaces.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else {
                oldSurfaces.forEach { $0.close() }
                return
            }
            self.surfaces.removeRetiring(oldSurfaces).forEach { $0.close() }
        }
    }

    /// 停止动态壁纸时淡出，露出下面的静态壁纸
    private func fadeOut(_ oldSurfaces: [Surface]) {
        guard !oldSurfaces.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            oldSurfaces.forEach { $0.window.animator().alphaValue = 0 }
        } completionHandler: {
            MainActor.assumeIsolated {
                oldSurfaces.forEach { $0.close() }
            }
        }
    }

    private func tearDownWindows() {
        revealedWindows.removeAll()
        removeMouseTracking()
        fadeOut(surfaces.removeAll())
    }

    private func removeMouseTracking() {
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors.removeAll()
    }

    private func updatePlayback() {
        // 手动暂停优先；自动暂停条件解除后自动继续
        // 全屏只暂停被盖住的那块屏幕，其他条件暂停所有屏幕
        let blocked = isSystemSuspended || !autoPauseReasons.subtracting([.fullScreen]).isEmpty
        let covered = autoPause.fullScreenDisplays
        for (window, player) in zip(windows, players) {
            let isCovered = window.screen.map { covered.contains($0.displayUUID) } ?? false
            let shouldPlay = !isPaused && !blocked && !isCovered && !isOccluded(window)
            shouldPlay ? player.play() : player.pause()
        }
        // 播放列表只在所有屏幕都被暂停时才停止轮换（手动暂停由播放列表自己处理）
        let allCovered = !windows.isEmpty && windows.allSatisfy { $0.screen.map { covered.contains($0.displayUUID) } ?? false }
        PlaylistManager.shared.setAutomaticPlaybackPaused(blocked || allCovered)
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

    // MARK: - Freeze on quit

    /// 退出 App 前把每块屏幕当前显示的画面设为系统壁纸：动态壁纸定格成静态，而不是露出黑屏或旧壁纸
    func freezeCurrentFrame() async {
        guard isActive, !windows.isEmpty else { return }
        let folder = Self.posterFolder
        let stamp = Int(Date().timeIntervalSince1970)
        var written: Set<String> = []

        for (index, (window, player)) in zip(windows, players).enumerated() {
            guard let screen = window.screen, let image = await player.snapshot(),
                  !DesktopSettings.disabledDisplayIDs.contains(screen.displayUUID) else { continue }
            let url = folder.appendingPathComponent("frozen-\(index)-\(stamp).png")
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                  (try? data.write(to: url, options: .atomic)) != nil else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            written.insert(url.lastPathComponent)
        }

        // 保留仍被系统使用的图片（包括禁用屏幕及快照失败的屏幕）。
        let referenced = Set(NSScreen.screens.compactMap { screen -> String? in
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else { return nil }
            return url.lastPathComponent
        })
        let old = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in old where name.hasPrefix("frozen-") && !written.contains(name) && !referenced.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    nonisolated private static var posterFolder: URL {
        let fm = FileManager.default
        let folder = ((try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory)
            .appendingPathComponent("wallhaven/LivePosters", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// 把封面设为系统静态壁纸：App 退出后桌面仍保持一致的画面
    private func setStaticPoster(for content: LiveContent) {
        guard DesktopSettings.bool(DesktopSettings.syncStaticWallpaper, default: true) else { return }
        Task {
            guard let posterURL = try? await Self.makePoster(for: content) else { return }
            // 期间可能已切换到别的壁纸
            guard self.current == content else { return }
            for screen in NSScreen.screens where !DesktopSettings.disabledDisplayIDs.contains(screen.displayUUID) {
                try? NSWorkspace.shared.setDesktopImageURL(posterURL, for: screen, options: [:])
            }
        }
    }

    nonisolated private static func makePoster(for content: LiveContent) async throws -> URL {
        let fm = FileManager.default
        let folder = posterFolder

        // 每个内容一个独立文件名，系统才会刷新壁纸（v2：跳过黑帧，旧的黑色封面会重新生成）
        let hash = SHA256.hash(data: Data(content.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let posterURL = folder.appendingPathComponent("poster-v2-\(hash).png")
        if fm.fileExists(atPath: posterURL.path) { return posterURL }

        let cgImage: CGImage
        switch content.kind {
        case .video:
            cgImage = try await firstFrame(of: content.url)
        case .workshop:
            let item = WorkshopItem.load(from: content.url)
            if let videoURL = item?.nativeVideoURL {
                cgImage = try await firstFrame(of: videoURL)
            } else if let preview = item?.previewURL, let cg = posterFrame(ofImageAt: preview) {
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

    /// 视频的封面帧：依次尝试几个时间点，跳过开头淡入的黑帧
    nonisolated private static func firstFrame(of url: URL) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let candidates = [0, 1, 2, duration * 0.25, duration * 0.5].filter { $0 < max(duration, 0.1) }
        var fallback: CGImage?
        for seconds in candidates {
            guard let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else { continue }
            if averageBrightness(of: image) > 12 { return image }
            fallback = fallback ?? image
        }
        if let fallback { return fallback }
        return try await generator.image(at: .zero).image
    }

    /// 图片（含 GIF）的封面帧：GIF 跳过开头的黑帧
    nonisolated private static func posterFrame(ofImageAt url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        let candidates = count > 1 ? [0, count / 8, count / 4, count / 3, count / 2] : [0]
        var fallback: CGImage?
        for index in candidates where index < count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            if averageBrightness(of: image) > 12 { return image }
            fallback = fallback ?? image
        }
        return fallback
    }

    /// 缩到 8×8 求平均亮度（0～255）
    nonisolated private static func averageBrightness(of image: CGImage) -> Int {
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        guard let context = CGContext(
            data: &pixels, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 255 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        var total = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            total += Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
        }
        return total / (64 * 3)
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

        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let window = notification.object as? NSWindow,
                      self.windows.contains(where: { $0 === window }) else { return }
                self.updatePlayback()
            }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 暂停相关的开关可能变了
                self.updatePlayback()
                let signature = Self.currentLayoutSignature
                guard signature != self.layoutSignature else { return }
                self.layoutSignature = signature
                if self.isActive { self.rebuildWindows() }
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
