//
//  LocalMediaViewModel.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct LocalMediaItem: Identifiable, Hashable, Sendable {
    let url: URL
    let creationDate: Date
    let fileSize: Int

    // 用文件路径作为稳定 ID，重新加载后选中状态不会丢失
    var id: URL { url }
    var isVideo: Bool { MediaType.isVideo(url) }
    var displayName: String { url.deletingPathExtension().lastPathComponent }
}

final class LocalMediaViewModel: ObservableObject {
    @Published private(set) var items: [LocalMediaItem] = []

    private let toast = ToastCenter.shared

    private var directoryURL: URL? {
        let downloadPath = DownloadLocation.currentPath
        guard !downloadPath.isEmpty else { return nil }
        return URL(fileURLWithPath: downloadPath, isDirectory: true)
    }

    func loadMedia() {
        guard let directoryURL else { return }

        let fm = FileManager.default
        if !fm.fileExists(atPath: directoryURL.path) {
            items = []
            return
        }

        do {
            let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
            let urls = try fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)
            var loadedItems: [LocalMediaItem] = []
            for url in urls where MediaType.isSupported(url) {
                let attrs = try url.resourceValues(forKeys: Set(keys))
                loadedItems.append(LocalMediaItem(
                    url: url,
                    creationDate: attrs.creationDate ?? .distantPast,
                    fileSize: attrs.fileSize ?? 0
                ))
            }
            items = loadedItems.sorted { $0.creationDate > $1.creationDate }
        } catch {
            toast.show(error.localizedDescription, style: .error)
        }
    }

    /// 从 Finder 导入图片或视频（复制到下载目录）
    func importFiles() {
        guard let directoryURL else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie]
        panel.message = "选择要导入的图片或视频（视频可设为动态壁纸）"
        panel.prompt = "导入"
        guard panel.runModal() == .OK else { return }

        let fm = FileManager.default
        var imported = 0
        do {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            for source in panel.urls where MediaType.isSupported(source) {
                let destination = directoryURL.appendingPathComponent(source.lastPathComponent)
                guard !fm.fileExists(atPath: destination.path) else { continue }
                try fm.copyItem(at: source, to: destination)
                imported += 1
            }
            loadMedia()
            toast.show(imported > 0 ? "已导入 \(imported) 个文件" : "没有新文件需要导入", style: .success)
        } catch {
            toast.show("导入失败：\(error.localizedDescription)", style: .error)
        }
    }

    func delete(item: LocalMediaItem) {
        do {
            // 移到废纸篓，可恢复
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            if LiveWallpaperController.shared.currentURL == item.url {
                LiveWallpaperController.shared.stop()
            }
            items.removeAll { $0.id == item.id }
            toast.show("已移到废纸篓", style: .info)
        } catch {
            toast.show(error.localizedDescription, style: .error)
        }
    }

    func applyWallpaper(_ item: LocalMediaItem) {
        do {
            try WallpaperManager.applyWallpaper(from: item.url)
            toast.show(item.isVideo ? "动态壁纸已启用" : "壁纸已应用", style: .success)
        } catch {
            toast.show(error.localizedDescription, style: .error)
        }
    }
}
