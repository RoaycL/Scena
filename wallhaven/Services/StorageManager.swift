//
//  StorageManager.swift
//  wallhaven
//
//  统一的存储位置：所有下载内容放在同一个根目录下，可以设到外接盘
//    <根目录>/Wallhaven/                                     wallhaven 图片、导入的图片和视频
//    <根目录>/Workshop/steamapps/workshop/content/431960/   创意工坊壁纸（steamcmd +force_install_dir）
//  未设置根目录时沿用默认位置（~/Pictures/Wallhaven 和 Steam 默认工坊目录）。
//

import AppKit
import Combine
import Kingfisher

extension Notification.Name {
    static let storageLocationDidChange = Notification.Name("wallhaven.storageLocationDidChange")
}

final class StorageManager: ObservableObject {
    static let shared = StorageManager()

    static let rootKey = "storage.rootPath"

    struct Usage {
        var wallpapers: Int64 = 0
        var workshop: Int64 = 0
        var cache: Int64 = 0
    }

    struct VolumeInfo {
        let name: String
        let available: Int64
        let total: Int64
        let isExternal: Bool
    }

    @Published private(set) var rootPath: String?
    @Published private(set) var isMigrating = false
    @Published private(set) var migrationProgress: (done: Int, total: Int) = (0, 0)
    @Published private(set) var usage = Usage()
    @Published private(set) var isAvailable = true

    private var observers: [NSObjectProtocol] = []

    private init() {
        rootPath = UserDefaults.standard.string(forKey: Self.rootKey)
        isAvailable = Self.isReachable(rootURL)
        observeVolumes()
    }

    // MARK: - Locations

    var rootURL: URL? { rootPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    /// 图片 / 视频目录（与旧版「下载路径」设置共用同一个 key）
    var wallpaperFolder: URL { URL(fileURLWithPath: DownloadLocation.currentPath, isDirectory: true) }

    /// steamcmd 的安装目录（+force_install_dir）；nil 表示使用 steamcmd 默认位置
    var workshopInstallDir: URL? { rootURL?.appendingPathComponent("Workshop", isDirectory: true) }

    /// App 管理的创意工坊下载目录
    var workshopContentFolder: URL {
        guard let installDir = workshopInstallDir else { return WorkshopLibrary.steamContentFolder }
        return installDir.appendingPathComponent("steamapps/workshop/content/\(WorkshopConstants.appID)", isDirectory: true)
    }

    // MARK: - Availability

    /// 外接盘是否已连接（路径在 /Volumes/<名称> 下时检查挂载状态）
    nonisolated static func isReachable(_ url: URL?) -> Bool {
        guard let url else { return true }
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 3, parts[1] == "Volumes" else { return true }
        let volumeRoot = URL(fileURLWithPath: "/Volumes/\(parts[2])", isDirectory: true)
        return (try? volumeRoot.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true
    }

    nonisolated static func volumeName(of url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName)
            ?? url.standardizedFileURL.pathComponents.dropFirst(2).first
            ?? url.lastPathComponent
    }

    /// 写入前检查：外接盘未连接时报错，避免在 /Volumes 下误建同名文件夹
    func ensureAvailable() throws {
        guard Self.isReachable(rootURL) else {
            throw WallperError.wallpaper("存储盘「\(rootURL.map(Self.volumeName) ?? "")」未连接，请连接后重试。")
        }
    }

    func volumeInfo() -> VolumeInfo? {
        let url = rootURL ?? wallpaperFolder.deletingLastPathComponent()
        guard Self.isReachable(url) else { return nil }
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeIsInternalKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return VolumeInfo(
            name: values.volumeName ?? "",
            available: values.volumeAvailableCapacityForImportantUsage ?? 0,
            total: Int64(values.volumeTotalCapacity ?? 0),
            isExternal: values.volumeIsInternal == false
        )
    }

    // MARK: - Usage & cache

    func refreshUsage() {
        let wallpaperFolder = wallpaperFolder
        let workshopFolder = workshopContentFolder
        Task {
            async let wallpapers = Task.detached { Self.size(of: wallpaperFolder) }.value
            async let workshop = Task.detached { Self.size(of: workshopFolder) }.value
            let cache = Int64((try? await ImageCache.default.diskStorageSize) ?? 0)
            usage = Usage(wallpapers: await wallpapers, workshop: await workshop, cache: cache)
        }
    }

    func clearImageCache() {
        ImageCache.default.clearMemoryCache()
        Task {
            await ImageCache.default.clearDiskCache()
            refreshUsage()
            ToastCenter.shared.show("图片缓存已清除", style: .success)
        }
    }

    /// 限制图片缓存大小，避免缩略图缓存无限增长
    static func configureImageCache() {
        let cache = ImageCache.default
        cache.diskStorage.config.sizeLimit = 1024 * 1024 * 1024
        cache.diskStorage.config.expiration = .days(14)
        cache.memoryStorage.config.totalCostLimit = 300 * 1024 * 1024
    }

    nonisolated private static func size(of folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    // MARK: - Migration

    /// 把存储位置改到 newRoot（nil = 恢复默认位置），并移动已下载的内容
    func changeLocation(to newRoot: URL?) {
        guard !isMigrating else { return }
        // 下载过程中移动目录会损坏正在写入的文件
        guard !SteamCMDDownloader.shared.isBusy else {
            ToastCenter.shared.show("创意工坊壁纸正在下载，请等下载完成后再更改存储位置", style: .error)
            return
        }
        let fm = FileManager.default
        let oldWallpapers = wallpaperFolder
        let oldWorkshop = workshopContentFolder

        let newWallpapers = newRoot?.appendingPathComponent("Wallhaven", isDirectory: true)
            ?? URL(fileURLWithPath: DownloadLocation.defaultPath, isDirectory: true)
        let newWorkshop = newRoot?
            .appendingPathComponent("Workshop/steamapps/workshop/content/\(WorkshopConstants.appID)", isDirectory: true)
            ?? WorkshopLibrary.steamContentFolder

        let pairs = [(oldWallpapers, newWallpapers), (oldWorkshop, newWorkshop)]
            .filter { $0.0.standardizedFileURL != $0.1.standardizedFileURL }

        isMigrating = true
        Task {
            var moved = 0, skipped = 0
            var failure: String?

            // 检查目标盘剩余空间（同一块盘内移动不占额外空间）
            let target = newRoot ?? newWallpapers.deletingLastPathComponent()
            let needed = await Task.detached {
                pairs.reduce(Int64(0)) { total, pair in
                    total + (Self.sameVolume(pair.0, target) ? 0 : Self.size(of: pair.0))
                }
            }.value
            let available = (try? target.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? .max
            if needed > available {
                let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                ToastCenter.shared.show("目标盘空间不足：需要 \(format(needed))，剩余 \(format(available))", style: .error)
                isMigrating = false
                return
            }

            do {
                var jobs: [(URL, URL)] = []
                for (source, destination) in pairs {
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                    let children = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                    jobs += children.map { ($0, destination.appendingPathComponent($0.lastPathComponent)) }
                }
                migrationProgress = (0, jobs.count)
                ToastCenter.shared.show("正在移动 \(jobs.count) 项到新位置…", style: .progress)

                for (index, job) in jobs.enumerated() {
                    // 跨盘移动是「复制 + 删除」，放到后台执行
                    let result = await Task.detached { () -> Result<Bool, Error> in
                        if FileManager.default.fileExists(atPath: job.1.path) { return .success(false) }
                        do {
                            try FileManager.default.moveItem(at: job.0, to: job.1)
                            return .success(true)
                        } catch {
                            return .failure(error)
                        }
                    }.value
                    switch result {
                    case .success(true): moved += 1
                    case .success(false): skipped += 1
                    case .failure(let error):
                        skipped += 1
                        failure = error.localizedDescription
                    }
                    migrationProgress = (index + 1, jobs.count)
                }

                // 删除已清空的旧目录
                for (source, _) in pairs {
                    if let rest = try? fm.contentsOfDirectory(atPath: source.path), rest.filter({ !$0.hasPrefix(".") }).isEmpty,
                       source.standardizedFileURL != WorkshopLibrary.steamContentFolder.standardizedFileURL {
                        try? fm.removeItem(at: source)
                    }
                }
            } catch {
                failure = error.localizedDescription
            }

            // 切换设置并更新引用了旧路径的地方
            UserDefaults.standard.set(newWallpapers.path, forKey: DownloadLocation.storageKey)
            if let newRoot {
                UserDefaults.standard.set(newRoot.path, forKey: Self.rootKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.rootKey)
            }
            rootPath = newRoot?.path
            isAvailable = Self.isReachable(rootURL)
            for (source, destination) in pairs {
                PlaylistManager.shared.remapPaths(from: source.path, to: destination.path)
                LiveWallpaperController.shared.remapPath(from: source.path, to: destination.path)
            }
            NotificationCenter.default.post(name: .storageLocationDidChange, object: nil)

            isMigrating = false
            refreshUsage()
            if let failure {
                ToastCenter.shared.show("已移动 \(moved) 项，\(skipped) 项未移动：\(failure)", style: .error)
            } else {
                ToastCenter.shared.show(skipped > 0 ? "已移动 \(moved) 项（\(skipped) 项目标位置已存在，保留原文件）" : "存储位置已更改，已移动 \(moved) 项", style: .success)
            }
        }
    }

    nonisolated private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: URLResourceKey = .volumeIdentifierKey
        guard let va = try? a.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject,
              let vb = try? b.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject else { return false }
        return va.isEqual(vb)
    }

    // MARK: - Volume events

    private func observeVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let available = Self.isReachable(self.rootURL)
                    guard available != self.isAvailable else { return }
                    self.isAvailable = available
                    NotificationCenter.default.post(name: .storageLocationDidChange, object: nil)
                    if available {
                        ToastCenter.shared.show("存储盘已连接", style: .success)
                        // 外接盘拔掉期间没能恢复的动态壁纸，重新连接后自动恢复
                        if !LiveWallpaperController.shared.isActive { LiveWallpaperController.shared.restore() }
                    } else {
                        ToastCenter.shared.show("存储盘已断开，已下载的壁纸暂时不可用", style: .error)
                    }
                }
            })
        }
    }
}
