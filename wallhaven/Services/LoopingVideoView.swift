//
//  LoopingVideoView.swift
//  wallhaven
//

import AppKit
import AVFoundation
import SwiftUI

nonisolated enum MediaType {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp", "gif"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    static func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return imageExtensions.contains(ext) || videoExtensions.contains(ext)
    }
}

/// 文件大小显示：始终用数字（ByteCountFormatter 默认把 0 显示成英文「Zero KB」）
nonisolated enum FileSizeText {
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    static func string(_ bytes: Int) -> String { string(Int64(bytes)) }
}

/// 静音、无缝循环播放的视频 NSView，App 内背景和桌面动态壁纸共用
final class LoopingVideoNSView: NSView {
    private let player = AVQueuePlayer()
    private let playerLayer = AVPlayerLayer()
    private var looper: AVPlayerLooper?
    private var readyObservation: NSKeyValueObservation?
    private var readyCallbacks: [() -> Void] = []
    /// 调用方希望的播放状态（play / pause）
    private var wantsPlaying = true
    /// 所在窗口被完全挡住时自动暂停（App 内预览用；桌面壁纸由 LiveWallpaperController 统一处理）
    private let pausesWhenHidden: Bool
    private var occlusionObserver: NSObjectProtocol?
    private var isStopped = false

    /// - includeAudio: 不需要声音时只解码画面轨。AVPlayer 静音时仍会解码、混音音频，去掉音轨能省下这部分开销
    init(url: URL, includeAudio: Bool = false, pausesWhenHidden: Bool = false) {
        self.pausesWhenHidden = pausesWhenHidden
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        player.isMuted = true
        // 不阻止显示器休眠，动态壁纸不应影响节能
        player.preventsDisplaySleepDuringVideoPlayback = false
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)

        if includeAudio {
            startLooping(AVPlayerItem(url: url))
        } else {
            Task { [weak self] in
                let item = await Self.videoOnlyItem(url: url) ?? AVPlayerItem(url: url)
                self?.startLooping(item)
            }
        }

        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.fireReady() }
        }
    }

    private func startLooping(_ item: AVPlayerItem) {
        guard !isStopped else { return }
        looper = AVPlayerLooper(player: player, templateItem: item)
        updatePlayback()
    }

    /// 只包含画面轨的播放项（读取失败时返回 nil，调用方退回原文件）
    private static func videoOnlyItem(url: URL) async -> AVPlayerItem? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration), duration.isNumeric, duration > .zero else { return nil }
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              (try? videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)) != nil else { return nil }
        videoTrack.preferredTransform = (try? await track.load(.preferredTransform)) ?? .identity
        return AVPlayerItem(asset: composition)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard pausesWhenHidden else { return }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePlayback() }
        }
        updatePlayback()
    }

    private func updatePlayback() {
        guard !isStopped else { return }
        // 第一帧出来之前不因遮挡暂停，否则切换时拿不到首帧
        let hidden = pausesWhenHidden && playerLayer.isReadyForDisplay
            && !(window?.occlusionState.contains(.visible) ?? false)
        if wantsPlaying && !hidden {
            if player.rate == 0 { player.play() }
        } else if player.rate != 0 {
            player.pause()
        }
    }

    /// 第一帧可以显示时回调（已就绪则立即回调）
    func whenReady(_ action: @escaping () -> Void) {
        if playerLayer.isReadyForDisplay {
            action()
        } else {
            readyCallbacks.append(action)
        }
    }

    private func fireReady() {
        updatePlayback()
        let callbacks = readyCallbacks
        readyCallbacks.removeAll()
        callbacks.forEach { $0() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func setVolume(_ volume: Double) {
        player.volume = Float(min(1, max(0, volume)))
        player.isMuted = volume <= 0
    }

    /// 截取当前播放到的这一帧
    func snapshot() async -> CGImage? {
        guard let asset = player.currentItem?.asset else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: player.currentTime()).image
    }

    /// 桌面壁纸的显示方式：保持原始长宽比时用背景色填充空白区域
    func setFit(keepAspectRatio: Bool, background: NSColor) {
        playerLayer.videoGravity = keepAspectRatio ? .resizeAspect : .resizeAspectFill
        layer?.backgroundColor = background.cgColor
    }

    func play() { wantsPlaying = true; updatePlayback() }
    func pause() { wantsPlaying = false; updatePlayback() }

    func stop() {
        isStopped = true
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        readyObservation = nil
        readyCallbacks.removeAll()
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }
}

struct LoopingVideoView: NSViewRepresentable {
    let url: URL
    var onReady: () -> Void = {}

    func makeNSView(context: Context) -> LoopingVideoNSView {
        // App 内预览没有声音；窗口隐藏、最小化或被挡住时暂停解码
        let view = LoopingVideoNSView(url: url, pausesWhenHidden: true)
        view.whenReady(onReady)
        return view
    }

    func updateNSView(_ nsView: LoopingVideoNSView, context: Context) {}

    static func dismantleNSView(_ nsView: LoopingVideoNSView, coordinator: ()) {
        nsView.stop()
    }
}
