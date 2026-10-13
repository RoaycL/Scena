//
//  GalleryItem.swift
//  wallhaven
//

import AppKit
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
        remote != nil ? DefaultImageProcessor.default : DownsamplingImageProcessor(size: CGSize(width: 480, height: 480))
    }

    /// 全尺寸图片来源（视频不适用）
    var fullSource: Source? {
        switch origin {
        case .remote(let wallpaper):
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
