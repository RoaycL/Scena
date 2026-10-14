//
//  PlaylistManager.swift
//  wallhaven
//
//  播放列表：可创建多个列表，按设定间隔自动切换壁纸（静态图、本地视频、工坊动态壁纸均可）
//

import AppKit
import Combine
import Foundation
import SwiftUI

struct PlaylistEntry: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case wallhaven, local, workshop
    }

    let id: String
    let kind: Kind
    let title: String
    /// 缩略图：远程 URL 字符串或本地文件路径
    let thumbnail: String?
    /// wallhaven 壁纸（播放时下载）
    let wallhaven: WallhavenWallpaper?
    /// 本地文件或工坊壁纸文件夹
    let path: String?

    var thumbnailURL: URL? {
        guard let thumbnail else { return nil }
        return thumbnail.hasPrefix("/") ? URL(fileURLWithPath: thumbnail) : URL(string: thumbnail)
    }

    var kindLabel: String {
        switch kind {
        case .wallhaven: "wallhaven"
        case .local: MediaType.isVideo(URL(fileURLWithPath: path ?? "")) ? "本地视频" : "本地图片"
        case .workshop: "工坊"
        }
    }

    private init(id: String, kind: Kind, title: String, thumbnail: String?, wallhaven: WallhavenWallpaper?, path: String?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.thumbnail = thumbnail
        self.wallhaven = wallhaven
        self.path = path
    }

    /// 路径变化后的副本（本地文件的条目 ID 也随路径更新）
    func with(path: String?, thumbnail: String?) -> PlaylistEntry {
        let newID = kind == .local && path != nil ? "file-\(path!)" : id
        return PlaylistEntry(id: newID, kind: kind, title: title, thumbnail: thumbnail, wallhaven: wallhaven, path: path)
    }

    /// 从画廊条目创建；未下载的工坊壁纸返回 nil
    init?(_ item: GalleryItem) {
        switch item.origin {
        case .remote(let wallpaper):
            id = "wh-\(wallpaper.id)"
            kind = .wallhaven
            title = "wallhaven #\(wallpaper.id)"
            thumbnail = (wallpaper.thumbURL ?? wallpaper.path).absoluteString
            self.wallhaven = wallpaper
            path = nil
        case .local(let local):
            id = "file-\(local.url.path)"
            kind = .local
            title = local.displayName
            thumbnail = local.isVideo ? nil : local.url.path
            wallhaven = nil
            path = local.url.path
        case .workshop(let workshop):
            guard let folder = workshop.localFolder, workshop.type.isPlayable else { return nil }
            id = "ws-\(workshop.id)"
            kind = .workshop
            title = workshop.title
            thumbnail = workshop.previewURL.map { $0.isFileURL ? $0.path : $0.absoluteString }
            wallhaven = nil
            path = folder.path
        }
    }
}

struct Playlist: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var entries: [PlaylistEntry] = []
    /// 切换间隔（秒）
    var interval: TimeInterval = 1800
    var shuffle = false

    static let intervals: [(seconds: TimeInterval, label: String)] = [
        (60, "1 分钟"), (300, "5 分钟"), (900, "15 分钟"), (1800, "30 分钟"),
        (3600, "1 小时"), (10800, "3 小时"), (21600, "6 小时"), (43200, "12 小时"), (86400, "每天"),
    ]
}

final class PlaylistManager: ObservableObject {
    static let shared = PlaylistManager()

    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var activeID: UUID?
    @Published private(set) var currentEntryID: String?
    @Published private(set) var isPaused = false
    private var isAutomaticallyPaused = false
    @Published private(set) var nextChangeAt: Date?

    var activePlaylist: Playlist? { playlists.first { $0.id == activeID } }

    private var timer: Timer?
    /// 当前播放顺序（随机模式下是打乱后的条目 ID）
    private var order: [String] = []
    private let toast = ToastCenter.shared

    private enum Keys {
        static let activeID = "playlist.activeID"
        static let currentEntryID = "playlist.currentEntryID"
    }

    private static var storageURL: URL {
        let folder = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("wallhaven", isDirectory: true) ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("playlists.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.storageURL),
           let decoded = try? JSONDecoder().decode([Playlist].self, from: data) {
            playlists = decoded
        }
    }

    // MARK: - Editing

    @discardableResult
    func create(name: String? = nil, entries: [PlaylistEntry] = []) -> Playlist {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(id: UUID(), name: trimmedName.flatMap { $0.isEmpty ? nil : $0 } ?? "播放列表 \(playlists.count + 1)", entries: entries)
        playlists.append(playlist)
        save()
        downloadLocalCopies(of: entries)
        return playlist
    }

    /// wallhaven 壁纸加入播放列表时立即下载到本地（和「设为壁纸」一样存进 Scena/Wallhaven）：
    /// 轮到时不用再等下载，离线也能播放，也会出现在资料库里
    private func downloadLocalCopies(of entries: [PlaylistEntry]) {
        let wallpapers = entries.compactMap(\.wallhaven)
        guard !wallpapers.isEmpty else { return }
        Task {
            var failed = 0
            for wallpaper in wallpapers {
                do { _ = try await DownloadService().download(wallpaper) } catch { failed += 1 }
            }
            if failed > 0 {
                toast.show("\(failed) 张壁纸下载失败，轮到时会再试", style: .error)
            }
            NotificationCenter.default.post(name: .localMediaDidChange, object: nil)
        }
    }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        update(id) { $0.name = name }
    }

    func delete(_ id: UUID) {
        if activeID == id { stop() }
        playlists.removeAll { $0.id == id }
        save()
    }

    func add(_ entries: [PlaylistEntry], to id: UUID) {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return }
        let existing = Set(playlist.entries.map(\.id))
        let fresh = entries.filter { !existing.contains($0.id) }
        update(id) { $0.entries += fresh }
        if fresh.isEmpty {
            toast.show("「\(playlist.name)」中已有该壁纸", style: .info)
        } else {
            toast.show("已添加到「\(playlist.name)」", style: .success)
            downloadLocalCopies(of: fresh)
        }
        if activeID == id { syncOrder() }
    }

    func remove(_ entryIDs: Set<String>, from id: UUID) {
        update(id) { $0.entries.removeAll { entryIDs.contains($0.id) } }
        if activeID == id {
            syncOrder()
            if activePlaylist?.entries.isEmpty == true { stop() }
        }
    }

    func move(in id: UUID, from source: IndexSet, to destination: Int) {
        update(id) { $0.entries.move(fromOffsets: source, toOffset: destination) }
        if activeID == id { rebuildOrder() }
    }

    func setInterval(_ interval: TimeInterval, for id: UUID) {
        update(id) { $0.interval = interval }
        if activeID == id { scheduleTimer() }
    }

    func setShuffle(_ shuffle: Bool, for id: UUID) {
        update(id) { $0.shuffle = shuffle }
        if activeID == id { rebuildOrder() }
    }

    /// 存储位置迁移后，把引用旧目录的条目路径改到新目录
    func remapPaths(from oldPrefix: String, to newPrefix: String) {
        let remap: (String?) -> String? = { path in
            guard let path, path == oldPrefix || path.hasPrefix(oldPrefix + "/") else { return path }
            return newPrefix + path.dropFirst(oldPrefix.count)
        }
        var changed = false
        for playlistIndex in playlists.indices {
            for entryIndex in playlists[playlistIndex].entries.indices {
                let entry = playlists[playlistIndex].entries[entryIndex]
                let newPath = remap(entry.path)
                let newThumbnail = remap(entry.thumbnail)
                guard newPath != entry.path || newThumbnail != entry.thumbnail else { continue }
                playlists[playlistIndex].entries[entryIndex] = entry.with(path: newPath, thumbnail: newThumbnail)
                changed = true
            }
        }
        if changed { save() }
    }

    private func update(_ id: UUID, _ change: (inout Playlist) -> Void) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        change(&playlists[index])
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        try? data.write(to: Self.storageURL, options: .atomic)
    }

    // MARK: - Playback

    func play(_ id: UUID, startAt entryID: String? = nil) {
        guard let playlist = playlists.first(where: { $0.id == id }), !playlist.entries.isEmpty else {
            toast.show("播放列表是空的", style: .info)
            return
        }
        activeID = id
        isPaused = false
        rebuildOrder()
        let first = entryID ?? order.first
        if let first { applyEntry(first, attemptsLeft: order.count) }
        persistState()
        toast.show("开始播放「\(playlist.name)」", style: .success)
    }

    func stop() {
        isPaused = false
        timer?.invalidate()
        timer = nil
        activeID = nil
        currentEntryID = nil
        nextChangeAt = nil
        persistState()
    }

    func setPlaybackPaused(_ paused: Bool) {
        isPaused = paused
        if paused {
            timer?.invalidate()
            timer = nil
            nextChangeAt = nil
        } else {
            scheduleTimer()
        }
    }

    /// 自动暂停与手动暂停分开保存，条件解除不能撤销用户的暂停意图。
    func setAutomaticPlaybackPaused(_ paused: Bool) {
        guard paused != isAutomaticallyPaused else { return }
        isAutomaticallyPaused = paused
        scheduleTimer()
    }

    func next() { isPaused = false; step(by: 1) }
    func previous() { isPaused = false; step(by: -1) }

    /// 用户手动设置了其他壁纸：停止自动轮换，避免过一会儿又被换掉
    func userDidApplyManually() {
        guard let playlist = activePlaylist else { return }
        stop()
        toast.show("已停止播放列表「\(playlist.name)」", style: .info)
    }

    /// App 启动时恢复：只重新计时，不立即切换
    func restore() {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: Keys.activeID), let id = UUID(uuidString: raw),
              playlists.contains(where: { $0.id == id }) else { return }
        activeID = id
        currentEntryID = defaults.string(forKey: Keys.currentEntryID)
        rebuildOrder()
        scheduleTimer()
    }

    private func step(by offset: Int) {
        guard activeID != nil, !order.isEmpty else { return }
        let index = currentEntryID.flatMap { order.firstIndex(of: $0) } ?? -1
        var nextIndex = index + offset
        if nextIndex >= order.count {
            // 随机模式每轮结束重新打乱
            if activePlaylist?.shuffle == true { rebuildOrder(keepCurrentFirst: false) }
            nextIndex = 0
        } else if nextIndex < 0 {
            nextIndex = order.count - 1
        }
        applyEntry(order[nextIndex], attemptsLeft: order.count)
    }

    /// 列表内容增删后更新播放顺序，不打乱当前进度：
    /// 顺序播放直接跟随列表；随机播放保留已排好的顺序，新加的壁纸随机插到还没播放的部分（这一轮内就会轮到）
    private func syncOrder() {
        guard let playlist = activePlaylist else { order = []; return }
        guard playlist.shuffle else { order = playlist.entries.map(\.id); return }
        order = Self.mergedShuffleOrder(order, entries: playlist.entries.map(\.id), current: currentEntryID)
    }

    nonisolated static func mergedShuffleOrder(_ order: [String], entries: [String], current: String?) -> [String] {
        let present = Set(entries)
        var result = order.filter { present.contains($0) }
        let known = Set(result)
        let currentIndex = current.flatMap { result.firstIndex(of: $0) } ?? -1
        for id in entries where !known.contains(id) {
            let position = Int.random(in: (currentIndex + 1)...result.count)
            result.insert(id, at: position)
        }
        return result
    }

    private func rebuildOrder(keepCurrentFirst: Bool = true) {
        guard let playlist = activePlaylist else { order = []; return }
        var ids = playlist.entries.map(\.id)
        if playlist.shuffle {
            ids.shuffle()
            // 避免新一轮第一张和刚播放的重复
            if !keepCurrentFirst, ids.count > 1, ids.first == currentEntryID { ids.swapAt(0, 1) }
        }
        order = ids
    }

    private func applyEntry(_ entryID: String, attemptsLeft: Int) {
        guard let entry = activePlaylist?.entries.first(where: { $0.id == entryID }) else { return }
        currentEntryID = entryID
        persistState()
        scheduleTimer()

        Task {
            do {
                try await apply(entry)
            } catch {
                toast.show("「\(entry.title)」无法播放：\(error.localizedDescription)", style: .error)
                // 跳过失败的条目；全部失败时停止，避免死循环
                if attemptsLeft > 1, let index = order.firstIndex(of: entryID), order.count > 1 {
                    applyEntry(order[(index + 1) % order.count], attemptsLeft: attemptsLeft - 1)
                } else {
                    stop()
                }
            }
        }
    }

    private func apply(_ entry: PlaylistEntry) async throws {
        switch entry.kind {
        case .wallhaven:
            guard let wallpaper = entry.wallhaven else { throw WallperError.wallpaper("缺少壁纸信息。") }
            let fileURL = try await DownloadService().download(wallpaper)
            try WallpaperManager.applyWallpaper(from: fileURL)
        case .local:
            guard let path = entry.path, FileManager.default.fileExists(atPath: path) else {
                throw WallperError.wallpaper("文件不存在。")
            }
            try WallpaperManager.applyWallpaper(from: URL(fileURLWithPath: path))
        case .workshop:
            guard let path = entry.path, let item = WorkshopItem.load(from: URL(fileURLWithPath: path)) else {
                throw WallperError.wallpaper("工坊壁纸已被删除。")
            }
            try LiveWallpaperController.shared.start(workshop: item)
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        guard let playlist = activePlaylist, !isPaused, !isAutomaticallyPaused else { nextChangeAt = nil; return }
        nextChangeAt = Date().addingTimeInterval(playlist.interval)
        timer = Timer.scheduledTimer(withTimeInterval: playlist.interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
        }
    }

    private func persistState() {
        let defaults = UserDefaults.standard
        defaults.set(activeID?.uuidString, forKey: Keys.activeID)
        defaults.set(currentEntryID, forKey: Keys.currentEntryID)
    }
}

extension Notification.Name {
    /// 本地图片 / 视频有新增（资料库需要刷新）
    static let localMediaDidChange = Notification.Name("scena.localMediaDidChange")
}
