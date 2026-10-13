//
//  StorageManager.swift
//  wallhaven
//
//  统一的存储位置：所有内容放在同一个 Scena 文件夹下，可以设到外接盘
//    <所选位置>/Scena/Wallhaven/            wallhaven 下载的壁纸
//    <所选位置>/Scena/Wallpaper Engine/     创意工坊壁纸（steamcmd +force_install_dir，内含 steamapps/workshop/content/431960）
//    <所选位置>/Scena/Imported/             导入的图片和视频
//  未设置时沿用默认位置（~/Pictures/Wallhaven、其中的 Imported 子文件夹，和 Steam 默认工坊目录）。
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

    /// 存储目录内的文件夹名
    enum Layout {
        static let root = "Scena"
        static let wallhaven = "Wallhaven"
        static let workshop = "Wallpaper Engine"
        static let imported = "Imported"
        /// steamcmd 安装目录内的工坊内容路径
        static let workshopContent = "steamapps/workshop/content/\(WorkshopConstants.appID)"
    }

    struct Usage {
        var wallpapers: Int64 = 0
        var imported: Int64 = 0
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

    /// 导入的图片和视频
    var importFolder: URL {
        rootURL?.appendingPathComponent(Layout.imported, isDirectory: true)
            ?? wallpaperFolder.appendingPathComponent(Layout.imported, isDirectory: true)
    }

    /// steamcmd 的安装目录（+force_install_dir）；nil 表示使用 steamcmd 默认位置
    var workshopInstallDir: URL? { rootURL?.appendingPathComponent(Layout.workshop, isDirectory: true) }

    /// App 管理的创意工坊下载目录
    var workshopContentFolder: URL {
        guard let installDir = workshopInstallDir else { return WorkshopLibrary.steamContentFolder }
        return installDir.appendingPathComponent(Layout.workshopContent, isDirectory: true)
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
        let importFolder = importFolder
        let workshopFolder = workshopContentFolder
        Task {
            async let wallpapers = Task.detached { Self.size(of: wallpaperFolder) }.value
            async let imported = Task.detached { Self.size(of: importFolder) }.value
            async let workshop = Task.detached { Self.size(of: workshopFolder) }.value
            let cache = Int64((try? await ImageCache.default.diskStorageSize) ?? 0)
            var usage = Usage(wallpapers: await wallpapers, imported: await imported, workshop: await workshop, cache: cache)
            // 默认位置下导入文件夹在壁纸文件夹里面，避免重复计算
            if importFolder.path.hasPrefix(wallpaperFolder.path + "/") { usage.wallpapers -= usage.imported }
            self.usage = usage
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
        let oldImports = importFolder
        let oldWorkshop = workshopContentFolder

        let newWallpapers = newRoot?.appendingPathComponent(Layout.wallhaven, isDirectory: true)
            ?? URL(fileURLWithPath: DownloadLocation.defaultPath, isDirectory: true)
        let newImports = newRoot?.appendingPathComponent(Layout.imported, isDirectory: true)
            ?? newWallpapers.appendingPathComponent(Layout.imported, isDirectory: true)
        let newWorkshop = newRoot?
            .appendingPathComponent(Layout.workshop, isDirectory: true)
            .appendingPathComponent(Layout.workshopContent, isDirectory: true)
            ?? WorkshopLibrary.steamContentFolder

        // 先移导入文件夹：默认位置下它在壁纸文件夹里面，不能被当作壁纸一起移到 Wallhaven/
        let pairs = [(oldImports, newImports), (oldWallpapers, newWallpapers), (oldWorkshop, newWorkshop)]
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
                Self.remapReferences(from: source.path, to: destination.path)
            }
            // 壁纸文件夹里混着的导入文件（旧版本导入的）归到 Imported/
            Self.moveImportedFiles(from: newWallpapers, to: newImports)
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

    // MARK: - Layout upgrade

    /// 旧版本的目录结构（<根目录>/Wallhaven 里混着导入的文件、<根目录>/Workshop）整理成新结构：
    /// 根目录改名为 Scena、Workshop 改名为 Wallpaper Engine、导入的文件移到 Imported/。
    /// 都在同一块盘内改名或移动，瞬间完成；App 启动时在其他组件读取路径之前调用一次。
    func upgradeLayoutIfNeeded() {
        guard var root = rootURL, Self.isReachable(root), !SteamCMDDownloader.shared.isBusy else { return }
        let fm = FileManager.default
        let defaults = UserDefaults.standard

        // 1. 旧版本自动创建的 wallhaven 根目录改名为 Scena（只在里面只有本 App 的文件夹时）
        let knownNames: Set<String> = [Layout.wallhaven, "Workshop", Layout.workshop, Layout.imported, ".DS_Store"]
        let renamedRoot = root.deletingLastPathComponent().appendingPathComponent(Layout.root, isDirectory: true)
        if root.lastPathComponent.lowercased() == "wallhaven",
           let contents = try? fm.contentsOfDirectory(atPath: root.path),
           Set(contents).isSubset(of: knownNames),
           !fm.fileExists(atPath: renamedRoot.path),
           (try? fm.moveItem(at: root, to: renamedRoot)) != nil {
            Self.remapReferences(from: root.path, to: renamedRoot.path)
            root = renamedRoot
            defaults.set(root.path, forKey: Self.rootKey)
            rootPath = root.path
        }

        // 下载目录始终是 <根目录>/Wallhaven
        let wallhaven = root.appendingPathComponent(Layout.wallhaven, isDirectory: true)
        let oldDownloadPath = DownloadLocation.currentPath
        if oldDownloadPath != wallhaven.path {
            Self.remapReferences(from: oldDownloadPath, to: wallhaven.path)
            defaults.set(wallhaven.path, forKey: DownloadLocation.storageKey)
        }

        // 2. Workshop → Wallpaper Engine
        let oldWorkshop = root.appendingPathComponent("Workshop", isDirectory: true)
        let newWorkshop = root.appendingPathComponent(Layout.workshop, isDirectory: true)
        if fm.fileExists(atPath: oldWorkshop.path), !fm.fileExists(atPath: newWorkshop.path),
           (try? fm.moveItem(at: oldWorkshop, to: newWorkshop)) != nil {
            Self.remapReferences(from: oldWorkshop.path, to: newWorkshop.path)
        }

        // 3. 导入的文件：Wallhaven/Imported/ 和 Wallhaven/ 里非 wallhaven ID 命名的文件 → Imported/
        let imported = root.appendingPathComponent(Layout.imported, isDirectory: true)
        Self.moveImportedFiles(from: wallhaven.appendingPathComponent(Layout.imported, isDirectory: true), to: imported, movesEverything: true)
        Self.moveImportedFiles(from: wallhaven, to: imported)
        if let rest = try? fm.contentsOfDirectory(atPath: wallhaven.appendingPathComponent(Layout.imported).path),
           rest.filter({ !$0.hasPrefix(".") }).isEmpty {
            try? fm.removeItem(at: wallhaven.appendingPathComponent(Layout.imported, isDirectory: true))
        }
    }

    /// 把 source 里的导入文件移到 destination。movesEverything 为 false 时只移走不是 wallhaven ID 命名的媒体文件
    private static func moveImportedFiles(from source: URL, to destination: URL, movesEverything: Bool = false) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return }
        let toMove = files.filter { MediaType.isSupported($0) && (movesEverything || !LocalMediaViewModel.isWallhavenFileName($0)) }
        guard !toMove.isEmpty else { return }
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in toMove {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            guard !fm.fileExists(atPath: target.path), (try? fm.moveItem(at: file, to: target)) != nil else { continue }
            remapReferences(from: file.path, to: target.path)
        }
    }

    /// 更新引用了旧路径的地方：播放列表、动态壁纸、工坊库的自定义文件夹
    private static func remapReferences(from oldPath: String, to newPath: String) {
        PlaylistManager.shared.remapPaths(from: oldPath, to: newPath)
        LiveWallpaperController.shared.remapPath(from: oldPath, to: newPath)
        let key = "workshop.libraryFolders"
        if let folders = UserDefaults.standard.stringArray(forKey: key) {
            let remapped = folders.map { path in
                path.lowercased() == oldPath.lowercased() || path.lowercased().hasPrefix(oldPath.lowercased() + "/")
                    ? newPath + path.dropFirst(oldPath.count)
                    : path
            }
            if remapped != folders { UserDefaults.standard.set(remapped, forKey: key) }
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
