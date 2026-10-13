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

    init(url: URL) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        player.isMuted = true
        // 不阻止显示器休眠，动态壁纸不应影响节能
        player.preventsDisplaySleepDuringVideoPlayback = false
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)

        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()

        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.fireReady() }
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

    func play() { player.play() }
    func pause() { player.pause() }

    func stop() {
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

    func makeNSView(context: Context) -> LoopingVideoNSView {
        LoopingVideoNSView(url: url)
    }

    func updateNSView(_ nsView: LoopingVideoNSView, context: Context) {}

    static func dismantleNSView(_ nsView: LoopingVideoNSView, coordinator: ()) {
        nsView.stop()
    }
}
