//
//  LiveWallpaperController.swift
//  wallhaven
//

import AppKit
import AVFoundation
import Combine
import CryptoKit

/// 动态壁纸：在每块屏幕的桌面层级放一个无边框窗口循环播放视频
/// （位于系统壁纸之上、桌面图标之下，不接收鼠标事件）
final class LiveWallpaperController: ObservableObject {
    static let shared = LiveWallpaperController()

    @Published private(set) var currentURL: URL?
    @Published private(set) var isPaused = false

    var isActive: Bool { currentURL != nil }

    private let storageKey = "liveWallpaper.path"
    private var windows: [NSWindow] = []
    private var players: [LoopingVideoNSView] = []
    private var observers: [NSObjectProtocol] = []
    /// 系统原因（锁屏、睡眠）导致的暂停，与用户手动暂停分开记录
    private var isSystemSuspended = false

    private init() {
        observeSystemEvents()
    }

    /// App 启动时恢复上次的动态壁纸
    func restore() {
        guard let path = UserDefaults.standard.string(forKey: storageKey) else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            UserDefaults.standard.removeObject(forKey: storageKey)
            return
        }
        try? start(url)
    }

    func start(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WallperError.wallpaper("视频文件不存在。")
        }
        currentURL = url
        isPaused = false
        UserDefaults.standard.set(url.path, forKey: storageKey)
        rebuildWindows()
        setStaticPoster(for: url)
    }

    func stop() {
        tearDownWindows()
        currentURL = nil
        isPaused = false
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    func togglePause() {
        isPaused.toggle()
        updatePlayback()
    }

    // MARK: - Windows

    private func rebuildWindows() {
        tearDownWindows()
        guard let url = currentURL else { return }

        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            window.ignoresMouseEvents = true
            window.isOpaque = true
            window.hasShadow = false
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false

            let player = LoopingVideoNSView(url: url)
            window.contentView = player
            window.setFrame(screen.frame, display: true)
            window.orderFront(nil)

            windows.append(window)
            players.append(player)
        }
        updatePlayback()
    }

    private func tearDownWindows() {
        players.forEach { $0.stop() }
        windows.forEach { $0.orderOut(nil) }
        players.removeAll()
        windows.removeAll()
    }

    private func updatePlayback() {
        let shouldPlay = !isPaused && !isSystemSuspended
        players.forEach { shouldPlay ? $0.play() : $0.pause() }
    }

    // MARK: - Static poster

    /// 把视频首帧设为系统静态壁纸：App 退出后桌面仍保持一致的画面
    private func setStaticPoster(for url: URL) {
        Task {
            guard let posterURL = try? await Self.makePoster(for: url) else { return }
            // 期间可能已切换到别的壁纸
            guard self.currentURL == url else { return }
            for screen in NSScreen.screens {
                try? NSWorkspace.shared.setDesktopImageURL(posterURL, for: screen, options: [:])
            }
        }
    }

    nonisolated private static func makePoster(for url: URL) async throws -> URL {
        let fm = FileManager.default
        let folder = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("wallhaven/LivePosters", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        // 每个视频一个独立文件名，系统才会刷新壁纸
        let hash = SHA256.hash(data: Data(url.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let posterURL = folder.appendingPathComponent("poster-\(hash).png")
        if fm.fileExists(atPath: posterURL.path) { return posterURL }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let (cgImage, _) = try await generator.image(at: .zero)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw WallperError.wallpaper("无法生成视频封面。")
        }
        try data.write(to: posterURL, options: .atomic)
        return posterURL
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
