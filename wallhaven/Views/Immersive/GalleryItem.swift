//
//  GalleryItem.swift
//  wallhaven
//

import AppKit
import ImageIO
import Kingfisher

/// 画廊中的一项：在线壁纸或本地文件，三个页面共用同一套画廊组件
struct GalleryItem: Identifiable, Equatable {
    enum Origin: Equatable {
        case remote(WallhavenWallpaper)
        case local(LocalMediaItem)
        case workshop(WorkshopItem)
    }

    let origin: Origin

    var id: String {
        switch origin {
        case .remote(let wallpaper): "remote-\(wallpaper.id)"
        case .local(let item): "local-\(item.url.path)"
        case .workshop(let item): "workshop-\(item.id)"
        }
    }

    var remote: WallhavenWallpaper? {
        if case .remote(let wallpaper) = origin { return wallpaper }
        return nil
    }

    var local: LocalMediaItem? {
        if case .local(let item) = origin { return item }
        return nil
    }

    var workshop: WorkshopItem? {
        if case .workshop(let item) = origin { return item }
        return nil
    }

    var isVideo: Bool { local?.isVideo ?? false }

    /// 已下载、可在背景实时渲染的工坊壁纸
    var playableWorkshopItem: WorkshopItem? {
        guard let item = workshop, item.isDownloaded, item.type.isPlayable else { return nil }
        return item
    }

    /// 小图来源（缩略图条 + 背景的模糊占位）
    var thumbnailSource: Source? {
        switch origin {
        case .remote(let wallpaper):
            return (wallpaper.thumbURL ?? wallpaper.path).convertToSource()
        case .local(let item):
            if item.isVideo {
                return .provider(AVAssetImageDataProvider(assetURL: item.url, seconds: 1))
            }
            return .provider(LocalFileImageDataProvider(fileURL: item.url))
        case .workshop(let item):
            return Self.source(for: item.previewURL)
        }
    }

    private static func source(for url: URL?) -> Source? {
        guard let url else { return nil }
        return url.isFileURL ? .provider(LocalFileImageDataProvider(fileURL: url)) : url.convertToSource()
    }

    /// 缩略图处理器：在线缩略图本身很小，直接用原图（和背景占位共享缓存）；
    /// 本地文件是原图，需要下采样
    var thumbnailProcessor: ImageProcessor {
        switch origin {
        case .remote:
            return DefaultImageProcessor.default
        case .local:
            return DownsamplingImageProcessor(size: CGSize(width: 480, height: 480))
        case .workshop(let item):
            // 工坊预览多为 GIF，视频类的第一帧常是全黑（淡入），要挑一帧有内容的
            return GIFPosterFrameProcessor(maxPixelSize: item.previewURL?.isFileURL == true ? 960 : nil)
        }
    }

    /// 全尺寸图片来源（视频不适用）
    var fullSource: Source? {
        switch origin {
        case .remote(let wallpaper):
            // 已下载到本地的直接读本地文件：切换更快，离线也能看
            if let local = wallpaper.localFileURL { return .provider(LocalFileImageDataProvider(fileURL: local)) }
            return wallpaper.path.convertToSource()
        case .local(let item):
            return item.isVideo ? nil : .provider(LocalFileImageDataProvider(fileURL: item.url))
        case .workshop(let item):
            // 工坊封面分辨率较低，背景直接使用封面（已下载的条目会实时渲染）
            return Self.source(for: item.previewURL)
        }
    }
}

enum ImageSizing {
    /// 背景图下采样到最大屏幕尺寸，避免 8K 原图占用数百 MB 内存
    static var backgroundSize: CGSize {
        let maxSide = NSScreen.screens.map { max($0.frame.width, $0.frame.height) }.max() ?? 2560
        return CGSize(width: maxSide, height: maxSide)
    }

    static var scale: CGFloat {
        NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
    }

    static var backgroundOptions: KingfisherOptionsInfo {
        [.processor(DownsamplingImageProcessor(size: backgroundSize)), .scaleFactor(scale)]
    }
}

/// 从 GIF 中挑一帧作为封面：跳过开头的黑帧（视频壁纸的预览通常从黑屏淡入）。
/// 非 GIF 图片按原样解码；maxPixelSize 不为空时顺带下采样（本地大图）。
nonisolated struct GIFPosterFrameProcessor: ImageProcessor {
    let maxPixelSize: Int?

    var identifier: String {
        "wallhaven.gifPosterFrame.v1" + (maxPixelSize.map { "-\($0)" } ?? "")
    }

    func process(item: ImageProcessItem, options: KingfisherParsedOptionsInfo) -> KFCrossPlatformImage? {
        switch item {
        case .image(let image):
            return image
        case .data(let data):
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let count = CGImageSourceGetCount(source)
            // 依次尝试这些帧，取第一张不是接近全黑的
            let candidates = count > 1 ? [0, count / 8, count / 4, count / 3, count / 2] : [0]
            var chosen: CGImage?
            for index in candidates where index < count {
                guard let frame = makeFrame(source, index: index) else { continue }
                if chosen == nil { chosen = frame }
                if Self.averageBrightness(of: frame) > 12 {
                    chosen = frame
                    break
                }
            }
            return chosen.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
    }

    private func makeFrame(_ source: CGImageSource, index: Int) -> CGImage? {
        guard let maxPixelSize else { return CGImageSourceCreateImageAtIndex(source, index, nil) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    /// 缩到 8×8 求平均亮度（0～255）
    private static func averageBrightness(of image: CGImage) -> Int {
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
}

extension WallhavenWallpaper {
    /// 已下载到 Scena/Wallhaven 的本地文件（下载时以壁纸 ID 命名）
    var localFileURL: URL? {
        let ext = path.pathExtension.isEmpty ? "jpg" : path.pathExtension
        let url = URL(fileURLWithPath: DownloadLocation.currentPath, isDirectory: true).appendingPathComponent("\(id).\(ext)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
