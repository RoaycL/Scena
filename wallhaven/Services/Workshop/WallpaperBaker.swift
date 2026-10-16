//
//  WallpaperBaker.swift
//  wallhaven
//
//  把场景 / 网页壁纸「烘焙」成循环视频：桌面播放改用系统硬件解码，GPU 占用从网页实时渲染的
//  两三成降到接近 0。做法：在用户看不见的窗口里渲染壁纸，用播放页的 MediaRecorder 录下画面，
//  找出首尾最接近的一段作为循环，重新编码成 HEVC。原壁纸文件不动，删掉视频就回到实时渲染。
//  代价：鼠标、音乐、时间相关的互动效果在视频里没有了。
//

import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI

/// 烘焙结果的位置与有效性（壁纸更新后旧视频作废）
nonisolated enum BakedWallpapers {
    struct Record: Codable {
        let projectSize: Int
        let projectModified: Double
        let loopDuration: Double
        let createdAt: Date
    }

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.roayc.wallhaven/BakedWallpapers", isDirectory: true)
    }

    static func videoFile(for id: String) -> URL { folder.appendingPathComponent("\(id).mp4") }
    static func recordFile(for id: String) -> URL { folder.appendingPathComponent("\(id).json") }

    /// 有效的烘焙视频：文件存在，且壁纸的 project.json 没有变过
    static func videoURL(for item: WorkshopItem) -> URL? {
        guard item.type == .scene || item.type == .web, let folder = item.localFolder else { return nil }
        let video = videoFile(for: item.id)
        guard FileManager.default.fileExists(atPath: video.path),
              let data = try? Data(contentsOf: recordFile(for: item.id)),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              let stamp = projectStamp(folder) else { return nil }
        return stamp.size == record.projectSize && abs(stamp.modified - record.projectModified) < 1 ? video : nil
    }

    static func projectStamp(_ folder: URL) -> (size: Int, modified: Double)? {
        let values = try? folder.appendingPathComponent("project.json").resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values?.fileSize, let modified = values?.contentModificationDate else { return nil }
        return (size, modified.timeIntervalSince1970)
    }

    static func remove(id: String) {
        try? FileManager.default.removeItem(at: videoFile(for: id))
        try? FileManager.default.removeItem(at: recordFile(for: id))
    }

    static func canBake(_ item: WorkshopItem) -> Bool {
        item.isDownloaded && (item.type == .scene || item.type == .web)
    }
}

extension WorkshopItem {
    /// 桌面和画廊直接用硬件解码播放的视频：视频类壁纸的原片，或场景 / 网页壁纸的烘焙结果
    nonisolated var playbackVideoURL: URL? { nativeVideoURL ?? BakedWallpapers.videoURL(for: self) }
}

@MainActor
final class WallpaperBaker: ObservableObject {
    static let shared = WallpaperBaker()

    enum Phase: Equatable {
        case queued
        case preparing
        case recording(Double)
        case processing
        case failed(String)
    }

    @Published private(set) var phases: [String: Phase] = [:]
    /// 每完成或删除一次就变化，界面据此刷新「已转为视频」状态
    @Published private(set) var revision = 0

    private var queue: [WorkshopItem] = []
    private var currentID: String?
    private var currentTask: Task<Void, Never>?

    /// 录制时长：留足空间找循环点
    private let recordSeconds = 20.0
    /// 壁纸就绪后先跑一会儿（入场动画、粒子铺满）再录
    private let warmUpSeconds = 3.0

    func isBaked(_ item: WorkshopItem) -> Bool { BakedWallpapers.videoURL(for: item) != nil }

    func bake(_ item: WorkshopItem) {
        guard BakedWallpapers.canBake(item), phases[item.id] == nil || phases[item.id].map(\.isFailure) == true else { return }
        phases[item.id] = .queued
        queue.append(item)
        startNext()
    }

    func cancel(_ id: String) {
        queue.removeAll { $0.id == id }
        if currentID == id { currentTask?.cancel() }
        phases[id] = nil
    }

    /// 删除烘焙视频，回到实时渲染
    func removeBake(_ item: WorkshopItem) {
        BakedWallpapers.remove(id: item.id)
        phases[item.id] = nil
        revision += 1
        LiveWallpaperController.shared.reloadIfShowing(item)
    }

    private func startNext() {
        guard currentTask == nil, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        currentID = item.id
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await run(item)
                phases[item.id] = nil
                revision += 1
                ToastCenter.shared.show("「\(item.title)」已转为视频", style: .success)
                LiveWallpaperController.shared.reloadIfShowing(item)
            } catch is CancellationError {
                phases[item.id] = nil
            } catch {
                phases[item.id] = .failed(error.localizedDescription)
                ToastCenter.shared.show("转为视频失败：\(error.localizedDescription)", style: .error)
            }
            currentID = nil
            currentTask = nil
            startNext()
        }
    }

    // MARK: - Pipeline

    private func run(_ item: WorkshopItem) async throws {
        guard let folder = item.localFolder, let stamp = BakedWallpapers.projectStamp(folder) else { throw BakeError.missing }
        phases[item.id] = .preparing
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("scena-bake-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: raw) }
        try await record(item, to: raw)
        try Task.checkCancellation()
        phases[item.id] = .processing
        let asset = AVURLAsset(url: raw)
        let loop = try await Self.loopRange(of: asset)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: BakedWallpapers.folder, withIntermediateDirectories: true)
        let output = BakedWallpapers.videoFile(for: item.id)
        try await Self.export(asset, range: loop, to: output)
        let record = BakedWallpapers.Record(projectSize: stamp.size, projectModified: stamp.modified,
                                            loopDuration: loop.duration.seconds, createdAt: Date())
        try JSONEncoder().encode(record).write(to: BakedWallpapers.recordFile(for: item.id), options: .atomic)
    }

    /// 在看不见的窗口里渲染并录制。被完全遮挡或移出屏幕的窗口 WebKit 会停止渲染（录出来是静止画面），
    /// 所以窗口放在最上层、几乎完全透明，并且只有 1 个点留在屏幕边缘：系统认为它可见，用户看不到
    private func record(_ item: WorkshopItem, to file: URL) async throws {
        guard let screen = NSScreen.main else { throw BakeError.missing }
        // 录制分辨率跟随最清晰的屏幕，不超过 3840×2160（H.264 最大 4096 宽）
        let scale = screen.backingScaleFactor
        let pixels = NSScreen.screens.map { CGSize(width: $0.frame.width * $0.backingScaleFactor, height: $0.frame.height * $0.backingScaleFactor) }
            .max { $0.width * $0.height < $1.width * $1.height } ?? CGSize(width: 1920, height: 1080)
        let factor = min(1, 3840 / pixels.width, 2160 / pixels.height)
        let size = CGSize(width: (pixels.width * factor / scale).rounded(), height: (pixels.height * factor / scale).rounded())
        let origin = CGPoint(x: screen.frame.maxX - 1, y: screen.frame.minY)
        let window = NSWindow(contentRect: CGRect(origin: origin, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.animationBehavior = .none
        window.alphaValue = 0.01
        let player = WorkshopPlayerNSView(item: item, fps: 30)
        player.frame = CGRect(origin: .zero, size: size)
        window.contentView = player
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
        defer {
            player.stop()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        let seconds = recordSeconds
        let warmUp = warmUpSeconds
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var finished = false
                var nextIndex = 0
                let finish: (Result<Void, Error>) -> Void = { result in
                    guard !finished else { return }
                    finished = true
                    player.onMessage = nil
                    continuation.resume(with: result)
                }
                player.onMessage = { [weak self] message in
                    switch message["type"] as? String {
                    case "recordStarted":
                        self?.phases[item.id] = .recording(0)
                    case "recordChunk":
                        guard let index = message["index"] as? Int, index == nextIndex,
                              let base64 = message["data"] as? String, let data = Data(base64Encoded: base64) else {
                            finish(.failure(BakeError.recording)); return
                        }
                        nextIndex += 1
                        do { try handle.write(contentsOf: data) } catch { finish(.failure(error)); return }
                        self?.phases[item.id] = .recording(min(1, Double(nextIndex) / seconds))
                    case "recordDone":
                        finish(nextIndex > 0 ? .success(()) : .failure(BakeError.recording))
                    case "recordError":
                        finish(.failure(BakeError.unsupported))
                    default:
                        break
                    }
                }
                player.whenReady {
                    if case .failed = player.state { finish(.failure(BakeError.render)); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + warmUp) {
                        guard !finished else { return }
                        // 码率：4K 30fps 约 24 Mbps，之后还会重新编码成 HEVC
                        player.evaluate("__host.record(\(seconds), 24000000)")
                    }
                }
                // 兜底：渲染器卡住或录制没有结束
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds + warmUp + 40) {
                    finish(.failure(BakeError.timeout))
                }
            }
        } onCancel: {
            Task { @MainActor in player.stop() }
        }
    }

    /// 循环点：每 0.1 秒取一张缩略帧，在「起点 0.5～4 秒、长度至少 8 秒」的组合里找首尾最像的一对。
    /// 起点不固定在开头，能避开入场动画，也给随机运动（雨、粒子）更多对齐的机会
    nonisolated static func loopRange(of asset: AVAsset) async throws -> CMTimeRange {
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 4 else { throw BakeError.recording }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 64, height: 36)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        var frames: [(time: Double, pixels: [UInt8])] = []
        var time = 0.5
        while time < duration - 0.05 {
            try Task.checkCancellation()
            if let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
                frames.append((time, try pixels(image)))
            }
            time += 0.1
        }
        let minimumLength = min(8, duration * 0.5)
        var best: (start: Double, end: Double, score: Double) = (0.5, duration - 0.1, .greatestFiniteMagnitude)
        for first in frames where first.time <= 4 {
            for last in frames where last.time - first.time >= minimumLength {
                let score = zip(first.pixels, last.pixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
                // 同样相似时偏好更长的循环，重复感更弱
                let weighted = Double(score) * (1 - 0.01 * (last.time - first.time) / duration)
                if weighted < best.score { best = (first.time, last.time, weighted) }
            }
        }
        return CMTimeRange(start: CMTime(seconds: best.start, preferredTimescale: 600),
                           end: CMTime(seconds: best.end, preferredTimescale: 600))
    }

    nonisolated private static func pixels(_ image: CGImage) throws -> [UInt8] {
        let width = 64, height = 36
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw BakeError.recording
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// 导出循环段并消除接缝：最后 0.5 秒交叉淡化到「起点之前 0.5 秒」的画面，
    /// 结尾最后一帧因此正好是起点的前一帧，循环回到开头时画面连续（雨、粒子这类随机运动也没有跳变）
    nonisolated static func export(_ asset: AVAsset, range: CMTimeRange, to output: URL) async throws {
        try? FileManager.default.removeItem(at: output)
        guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw BakeError.export }
        let size = try await source.load(.naturalSize)
        let fade = CMTimeMinimum(CMTime(seconds: 0.5, preferredTimescale: 600), range.start)
        let length = range.duration

        let composition = AVMutableComposition()
        guard let main = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let tail = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw BakeError.export
        }
        try main.insertTimeRange(range, of: source, at: .zero)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = size
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: length)
        let mainLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: main)
        if fade > .zero {
            try tail.insertTimeRange(CMTimeRange(start: range.start - fade, duration: fade), of: source, at: length - fade)
            mainLayer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: CMTimeRange(start: length - fade, duration: fade))
            // 第一个是最上层：主画面在上、逐渐变透明，露出下面接近起点的画面
            instruction.layerInstructions = [mainLayer, AVMutableVideoCompositionLayerInstruction(assetTrack: tail)]
        } else {
            instruction.layerInstructions = [mainLayer]
        }
        videoComposition.instructions = [instruction]

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw BakeError.export
        }
        session.videoComposition = videoComposition
        session.shouldOptimizeForNetworkUse = true
        if #available(macOS 15.0, *) {
            try await session.export(to: output, as: .mp4)
        } else {
            session.outputURL = output
            session.outputFileType = .mp4
            await session.export()
            if session.status != .completed { throw session.error ?? BakeError.export }
        }
    }

    enum BakeError: LocalizedError {
        case missing, render, unsupported, recording, timeout, export

        var errorDescription: String? {
            switch self {
            case .missing: "壁纸文件不存在。"
            case .render: "壁纸渲染失败，无法录制。"
            case .unsupported: "这个壁纸的画面无法录制（不是画布渲染的网页壁纸）。"
            case .recording: "录制没有得到画面。"
            case .timeout: "录制超时。"
            case .export: "视频编码失败。"
            }
        }
    }
}

private extension WallpaperBaker.Phase {
    var isFailure: Bool { if case .failed = self { true } else { false } }
}

/// 信息面板里的「转为视频」按钮：未烘焙 → 进度环（点击取消）→ 已转为视频（点击恢复实时渲染）
struct BakeVideoButton: View {
    @ObservedObject private var baker = WallpaperBaker.shared
    let item: WorkshopItem

    var body: some View {
        // revision 变化时重新判断是否已烘焙
        let _ = baker.revision
        switch baker.phases[item.id] {
        case .queued, .preparing, .processing:
            progressButton(nil, help: baker.phases[item.id] == .processing ? "正在生成循环视频…（点击取消）" : "准备转为视频…（点击取消）")
        case .recording(let fraction):
            progressButton(fraction, help: "正在录制画面 \(Int(fraction * 100))%（点击取消）")
        case .failed, nil:
            if baker.isBaked(item) {
                CircleIconButton(systemImage: "film.fill", tint: .green,
                                 help: "已转为视频，桌面用硬件解码播放、更省电。点击恢复实时渲染") { baker.removeBake(item) }
            } else {
                CircleIconButton(systemImage: "film",
                                 help: "转为视频：录制约 20 秒画面生成循环视频，桌面改用硬件解码播放，更省电（鼠标、音乐等互动效果会消失）") {
                    baker.bake(item)
                }
            }
        }
    }

    private func progressButton(_ fraction: Double?, help: String) -> some View {
        Button { baker.cancel(item.id) } label: {
            ZStack {
                Circle().fill(.clear).frame(width: 32, height: 32).sceneGlass(in: Circle(), interactive: true)
                if let fraction {
                    Circle().trim(from: 0, to: fraction)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(3)
                        .animation(.easeOut(duration: 0.3), value: fraction)
                    Image(systemName: "film").font(.system(size: 11, weight: .medium))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
