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

/// 本地文件的来源
enum LocalMediaSource: Hashable, Sendable {
    /// 从 wallhaven 下载（文件名是 6 位壁纸 ID，如 l8vp7y.jpg）
    case wallhaven
    /// 用户导入的图片 / 视频
    case imported
}

struct LocalMediaItem: Identifiable, Hashable, Sendable {
    let url: URL
    let creationDate: Date
    let fileSize: Int
    let source: LocalMediaSource

    // 用文件路径作为稳定 ID，重新加载后选中状态不会丢失
    var id: URL { url }
    var isVideo: Bool { MediaType.isVideo(url) }
    var displayName: String { url.deletingPathExtension().lastPathComponent }
}

final class LocalMediaViewModel: ObservableObject {
    @Published private(set) var items: [LocalMediaItem] = []

    private let toast = ToastCenter.shared
    private var storageObserver: NSObjectProtocol?

    init() {
        storageObserver = NotificationCenter.default.addObserver(forName: .storageLocationDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadMedia() }
        }
    }

    private var directoryURL: URL? {
        let downloadPath = DownloadLocation.currentPath
        guard !downloadPath.isEmpty else { return nil }
        return URL(fileURLWithPath: downloadPath, isDirectory: true)
    }

    /// 导入的文件单独放在 Imported 子文件夹，和 wallhaven 下载的区分开
    private var importedURL: URL? {
        directoryURL?.appendingPathComponent("Imported", isDirectory: true)
    }

    /// wallhaven 壁纸 ID：6 位小写字母或数字
    nonisolated static func isWallhavenFileName(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent.wholeMatch(of: /[a-z0-9]{6}/) != nil
    }

    func loadMedia() {
        guard let directoryURL, let importedURL else { return }

        let fm = FileManager.default
        if !fm.fileExists(atPath: directoryURL.path) {
            items = []
            return
        }

        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        var loadedItems: [LocalMediaItem] = []
        // 根目录：wallhaven 下载的壁纸，以及旧版本导入的文件（按文件名区分）；Imported/：导入的文件
        for (folder, isImportFolder) in [(directoryURL, false), (importedURL, true)] {
            guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles) else { continue }
            for url in urls where MediaType.isSupported(url) {
                let attrs = try? url.resourceValues(forKeys: Set(keys))
                let isWallhaven = !isImportFolder && Self.isWallhavenFileName(url)
                loadedItems.append(LocalMediaItem(
                    url: url,
                    creationDate: attrs?.creationDate ?? .distantPast,
                    fileSize: attrs?.fileSize ?? 0,
                    source: isWallhaven ? .wallhaven : .imported
                ))
            }
        }
        items = loadedItems.sorted { $0.creationDate > $1.creationDate }
    }

    /// 从 Finder 导入图片或视频（复制到下载目录）
    func importFiles() {
        guard let directoryURL = importedURL else { return }
        do {
            try StorageManager.shared.ensureAvailable()
        } catch {
            toast.show(error.localizedDescription, style: .error)
            return
        }
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
        PlaylistManager.shared.userDidApplyManually()
        do {
            try WallpaperManager.applyWallpaper(from: item.url)
            toast.show(item.isVideo ? "动态壁纸已启用" : "壁纸已应用", style: .success)
        } catch {
            toast.show(error.localizedDescription, style: .error)
        }
    }
}
