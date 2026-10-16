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
    @Published private(set) var items: [LocalMediaItem] = [] {
        didSet {
            wallhavenIDs = Set(items.filter { $0.source == .wallhaven }.map { $0.url.deletingPathExtension().lastPathComponent })
        }
    }
    /// 已下载的 wallhaven 壁纸 ID（文件名就是 ID），用于显示「已下载」角标
    private(set) var wallhavenIDs: Set<String> = []

    private let toast = ToastCenter.shared
    private var storageObserver: NSObjectProtocol?
    private var mediaObserver: NSObjectProtocol?

    init() {
        storageObserver = NotificationCenter.default.addObserver(forName: .storageLocationDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadMedia() }
        }
        // 设为壁纸、加入播放列表时下载的 wallhaven 图片：刷新资料库
        mediaObserver = NotificationCenter.default.addObserver(forName: .localMediaDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadMedia() }
        }
    }

    private var directoryURL: URL? {
        let downloadPath = DownloadLocation.currentPath
        guard !downloadPath.isEmpty else { return nil }
        return URL(fileURLWithPath: downloadPath, isDirectory: true)
    }

    /// 导入的文件单独放在 Imported 文件夹，和 wallhaven 下载的区分开
    private var importedURL: URL? {
        StorageManager.shared.importFolder
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
        var videos: [URL] = []
        do {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            for source in panel.urls where MediaType.isSupported(source) {
                let destination = directoryURL.appendingPathComponent(source.lastPathComponent)
                guard !fm.fileExists(atPath: destination.path) else { continue }
                try fm.copyItem(at: source, to: destination)
                imported += 1
                if MediaType.isVideo(destination) { videos.append(destination) }
            }
            loadMedia()
            let importedVideos = videos
            Task(priority: .utility) { await VideoPosterCache.shared.prewarm(importedVideos) }
            toast.show(imported > 0 ? "已导入 \(imported) 个文件" : "没有新文件需要导入", style: .success)
        } catch {
            toast.show("导入失败：\(error.localizedDescription)", style: .error)
        }
    }

    func delete(item: LocalMediaItem) {
        do {
            // 移到废纸篓，可恢复；提示条上直接给「撤销」，不用去 Finder 里找
            var trashed: NSURL?
            try FileManager.default.trashItem(at: item.url, resultingItemURL: &trashed)
            if LiveWallpaperController.shared.currentURL == item.url {
                LiveWallpaperController.shared.stop()
            }
            items.removeAll { $0.id == item.id }
            let original = item.url
            toast.show("已移到废纸篓", style: .info, actionTitle: "撤销") { [weak self] in
                self?.restore(trashed as URL?, to: original)
            }
        } catch {
            toast.show(error.localizedDescription, style: .error)
        }
    }

    /// 撤销删除：从废纸篓移回原位置
    private func restore(_ trashed: URL?, to original: URL) {
        do {
            guard let trashed else { throw CocoaError(.fileNoSuchFile) }
            try FileManager.default.moveItem(at: trashed, to: original)
            loadMedia()
        } catch {
            toast.show("无法恢复：文件已不在废纸篓中", style: .error)
        }
    }

    func applyWallpaper(_ item: LocalMediaItem) {
        PlaylistManager.shared.userDidApplyManually()
        let feedbackID = GalleryItem(origin: .local(item)).id
        ApplyFeedback.shared.begin(feedbackID)
        do {
            try WallpaperManager.applyWallpaper(from: item.url)
            // 成功反馈在「设为壁纸」按钮上，不再弹提示条
            ApplyFeedback.shared.finish(feedbackID, success: true)
        } catch {
            ApplyFeedback.shared.finish(feedbackID, success: false)
            toast.show(error.localizedDescription, style: .error)
        }
    }
}
