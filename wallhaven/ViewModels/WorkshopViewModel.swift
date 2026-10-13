//
//  WorkshopViewModel.swift
//  wallhaven
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

final class WorkshopViewModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case library = "已下载"
        case subscribed = "已订阅"
        case online = "在线"

        var id: String { rawValue }
    }

    @Published var mode: Mode = .library
    @Published private(set) var libraryItems: [WorkshopItem] = []
    @Published private(set) var onlineItems: [WorkshopItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var downloadJobs: [WorkshopDownloadJob] = [] {
        didSet { persistDownloads() }
    }
    /// 正在退出的批次也保留在这里，确保恢复操作不会启动第二个进程。
    @Published private(set) var activeDownloads: Set<String> = []
    var downloading: Set<String> {
        Set(downloadJobs.filter { $0.state == .queued || $0.state == .downloading }.map(\.id))
    }

    // 订阅同步
    @Published private(set) var subscribedIDs: Set<String> = []
    @Published private(set) var subscribedItems: [WorkshopItem] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncAt: Date?
    @Published var subscribeOnDownload: Bool {
        didSet { UserDefaults.standard.set(subscribeOnDownload, forKey: Keys.subscribeOnDownload) }
    }
    /// 同时下载数量（每次 steamcmd 登录处理的条目数），超出的排队等待
    @Published var maxConcurrentDownloads: Int {
        didSet {
            let clamped = min(10, max(1, maxConcurrentDownloads))
            if clamped != maxConcurrentDownloads { maxConcurrentDownloads = clamped; return }
            UserDefaults.standard.set(clamped, forKey: Keys.maxConcurrentDownloads)
        }
    }
    @Published var autoDownloadSubscriptions: Bool {
        didSet { UserDefaults.standard.set(autoDownloadSubscriptions, forKey: Keys.autoDownload) }
    }

    @Published var query = ""
    @Published var filters: WorkshopFilters {
        didSet {
            if let data = try? JSONEncoder().encode(filters) {
                UserDefaults.standard.set(data, forKey: Keys.filters)
            }
        }
    }

    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: Keys.apiKey) }
    }
    @Published var steamUsername: String {
        didSet { UserDefaults.standard.set(steamUsername, forKey: Keys.username) }
    }
    @Published private(set) var extraFolders: [URL]

    private enum Keys {
        static let apiKey = "workshop.steamWebAPIKey"
        static let username = "workshop.steamUsername"
        static let folders = "workshop.libraryFolders"
        static let filters = "workshop.filters"
        static let subscribeOnDownload = "workshop.subscribeOnDownload"
        static let downloadJobs = "workshop.downloadJobs.v1"
        static let autoDownload = "workshop.autoDownloadSubscriptions"
        static let maxConcurrentDownloads = "workshop.maxConcurrentDownloads"
    }

    private let api = SteamWorkshopAPI()
    private let toast = ToastCenter.shared
    private var cursor: String?
    private var webPage = 1
    private var canLoadMore = true
    private var searchGeneration = UUID()
    private var libraryGeneration = UUID()
    private var searchTask: Task<Void, Never>?
    private var filterDebounce: Task<Void, Never>?
    private let account = SteamAccountSession.shared
    /// 下载队列：串行执行，每批最多 10 个条目共用一次 steamcmd 登录
    private var batchInterrupted = false
    private var isProcessingQueue = false
    private var storageObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var isShuttingDown = false

    init() {
        let defaults = UserDefaults.standard
        apiKey = defaults.string(forKey: Keys.apiKey) ?? ""
        steamUsername = defaults.string(forKey: Keys.username) ?? ""
        filters = defaults.data(forKey: Keys.filters).flatMap { try? JSONDecoder().decode(WorkshopFilters.self, from: $0) } ?? WorkshopFilters()
        // 去掉与默认目录或彼此之间只差大小写的重复文件夹（旧版本按区分大小写比较时加进来的）
        var seenFolders: Set<String> = [Self.pathKey(StorageManager.shared.workshopContentFolder), Self.pathKey(WorkshopLibrary.steamContentFolder)]
        let savedFolders = defaults.stringArray(forKey: Keys.folders) ?? []
        let uniqueFolders = savedFolders
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { seenFolders.insert(Self.pathKey($0)).inserted }
        if uniqueFolders.count != savedFolders.count {
            defaults.set(uniqueFolders.map(\.path), forKey: Keys.folders)
        }
        extraFolders = uniqueFolders
        subscribeOnDownload = defaults.object(forKey: Keys.subscribeOnDownload) as? Bool ?? true
        autoDownloadSubscriptions = defaults.object(forKey: Keys.autoDownload) as? Bool ?? true
        let savedConcurrency = defaults.integer(forKey: Keys.maxConcurrentDownloads)
        maxConcurrentDownloads = savedConcurrency == 0 ? 3 : min(10, max(1, savedConcurrency))
        if let data = defaults.data(forKey: Keys.downloadJobs),
           let saved = try? JSONDecoder().decode([WorkshopDownloadJob].self, from: data) {
            downloadJobs = WorkshopDownloadQueue.restored(saved)
        }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isShuttingDown = true
                self?.pauseAllDownloads()
            }
        }
        storageObserver = NotificationCenter.default.addObserver(forName: .storageLocationDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLibrary() }
        }
    }

    var hasAPIKey: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }
    var steamCMDPath: URL? { SteamCMDDownloader.locate() }

    /// 已下载模式在本地按关键词和筛选条件过滤；在线模式由服务端过滤
    var items: [WorkshopItem] {
        switch mode {
        case .library: libraryItems.filter { filters.matches($0, query: query) }
        case .subscribed: subscribedItems.filter { filters.matches($0, query: query) }
        case .online: onlineItems
        }
    }

    var isLoggedIn: Bool { account.isLoggedIn }

    func downloadState(of item: WorkshopItem) -> DownloadState {
        downloadJobs.first { $0.id == item.id }?.state ?? .none
    }

    func isSubscribed(_ item: WorkshopItem) -> Bool {
        subscribedIDs.contains(item.id)
    }

    /// 筛选条件变化：在线模式防抖后重新搜索（连续点选多个标签只发一次请求）
    func filtersDidChange() {
        guard mode == .online else { return }
        filterDebounce?.cancel()
        filterDebounce = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            search(reset: true)
        }
    }

    func resetFilters() {
        filters = WorkshopFilters()
    }

    /// 点击信息面板里的标签：题材标签加入筛选，其余作为关键词搜索
    func applyTag(_ tag: String) {
        if WorkshopTags.isGenre(tag) {
            filters.selectGenre(tag)
        } else {
            query = tag
            if mode == .online { search(reset: true) }
        }
    }

    /// 本地库根目录：Steam / steamcmd 默认下载目录 + 用户添加的文件夹
    var libraryRoots: [URL] {
        // App 管理的下载目录（可能在外接盘上）+ Steam 默认目录 + 用户添加的文件夹
        // macOS 文件系统不区分大小写，steamcmd 报告的路径可能是小写，按不区分大小写去重
        var seen = Set<String>()
        return ([StorageManager.shared.workshopContentFolder, WorkshopLibrary.steamContentFolder] + extraFolders)
            .filter { seen.insert(Self.pathKey($0)).inserted }
    }

    static func pathKey(_ url: URL) -> String {
        url.standardizedFileURL.path.lowercased()
    }

    // MARK: - Library

    func refreshLibrary() {
        Task { await refreshLibraryAndWait() }
    }

    /// 调用方可等待扫描，旧位置的慢扫描不能覆盖新库。
    @discardableResult
    private func refreshLibraryAndWait() async -> [WorkshopItem] {
        let generation = UUID()
        libraryGeneration = generation
        let roots = libraryRoots
        let scanned = await Task.detached { WorkshopLibrary.scan(roots: roots) }.value
        guard roots == libraryRoots else { return await refreshLibraryAndWait() }
        if libraryGeneration == generation {
            libraryItems = scanned
            mergeDownloadState()
        }
        return scanned
    }

    /// 导入本地文件夹：可以是单个壁纸文件夹（含 project.json），也可以是包含多个壁纸的目录
    /// （例如从 Windows 电脑拷来的 steamapps/workshop/content/431960）
    func addLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "选择 Wallpaper Engine 壁纸文件夹，或包含多个壁纸的工坊目录（…/workshop/content/431960）"
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }

        var folders = extraFolders
        for url in panel.urls where !folders.contains(url) {
            folders.append(url)
        }
        setExtraFolders(folders)
        refreshLibrary()
        toast.show("已添加 \(panel.urls.count) 个文件夹", style: .success)
    }

    func removeLibraryFolder(_ url: URL) {
        setExtraFolders(extraFolders.filter { $0 != url })
        refreshLibrary()
    }

    private func setExtraFolders(_ folders: [URL]) {
        extraFolders = folders
        UserDefaults.standard.set(folders.map(\.path), forKey: Keys.folders)
    }

    /// 把在线 / 订阅条目标记为已下载（关联本地文件夹）
    private func mergeDownloadState() {
        let local = Dictionary(libraryItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let merge: (WorkshopItem) -> WorkshopItem = { item in
            var item = item
            if let localItem = local[item.id] {
                item.localFolder = localItem.localFolder
                item.entryFile = localItem.entryFile
                // 已下载时优先用本地自带的预览图（线上接口查不到详情的受限条目没有预览图），
                // 线上缺失的类型、标签、分级也用本地 project.json 补上
                if let localPreview = localItem.previewURL { item.previewURL = localPreview }
                if item.type == .unknown { item.type = localItem.type }
                if item.tags.isEmpty { item.tags = localItem.tags }
                if item.contentRating == nil { item.contentRating = localItem.contentRating }
                if item.fileSize == 0 { item.fileSize = localItem.fileSize }
            } else {
                item.localFolder = nil
            }
            return item
        }
        onlineItems = onlineItems.map(merge)
        subscribedItems = subscribedItems.map(merge)
    }

    /// 移到废纸篓；unsubscribe 为 true 时同时取消 Steam 订阅（Windows 上也会移除）
    func delete(_ item: WorkshopItem, unsubscribe: Bool = false) {
        if unsubscribe { setSubscribed(item, false) }
        guard let folder = item.localFolder else { return }
        do {
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
            if LiveWallpaperController.shared.currentURL?.standardizedFileURL == folder.standardizedFileURL {
                LiveWallpaperController.shared.stop()
            }
            libraryItems.removeAll { $0.id == item.id }
            mergeDownloadState()
            toast.show("已移到废纸篓", style: .info)
        } catch {
            toast.show(error.localizedDescription, style: .error)
        }
    }

    // MARK: - Online

    func search(reset: Bool) {
        // 输入的是工坊链接 / ID 时直接按 ID 查询
        let ids = SteamWorkshopAPI.extractIDs(from: query)
        let isIDLookup = reset && !ids.isEmpty && !query.trimmingCharacters(in: .whitespaces).contains(" ")
        if reset {
            // 筛选条件变化时取消进行中的请求，否则新请求会被 isLoading 挡住
            searchTask?.cancel()
            searchGeneration = UUID()
            isLoading = false
            cursor = nil
            webPage = 1
            canLoadMore = true
            onlineItems = []
        }
        guard canLoadMore, !isLoading else { return }

        let generation = searchGeneration
        let requestQuery = query
        let requestFilters = filters
        let requestKey = apiKey.trimmingCharacters(in: .whitespaces)
        let requestCursor = cursor
        let requestPage = webPage
        isLoading = true
        searchTask = Task {
            defer {
                if searchGeneration == generation { isLoading = false }
            }
            do {
                let newItems: [WorkshopItem]
                var nextCursor = requestCursor
                var nextPage = requestPage
                let hasMore: Bool
                if isIDLookup {
                    newItems = try await api.details(ids: ids)
                    hasMore = false
                } else if !requestKey.isEmpty {
                    // 有 API Key：官方 QueryFiles 接口，更快更稳定
                    let page = try await api.query(
                        apiKey: requestKey,
                        text: requestQuery,
                        filters: requestFilters,
                        cursor: requestCursor
                    )
                    newItems = page.items
                    hasMore = page.nextCursor != nil && page.nextCursor != requestCursor
                    nextCursor = page.nextCursor
                } else {
                    // 无 API Key：解析工坊网页
                    newItems = try await api.browseWeb(
                        text: requestQuery,
                        filters: requestFilters,
                        page: requestPage
                    )
                    nextPage += 1
                    hasMore = !newItems.isEmpty
                }
                guard searchGeneration == generation, !Task.isCancelled else { return }
                cursor = nextCursor
                webPage = nextPage
                canLoadMore = hasMore
                var existing = Set(onlineItems.map(\.id))
                onlineItems.append(contentsOf: newItems.filter { existing.insert($0.id).inserted })
                mergeDownloadState()
            } catch {
                guard searchGeneration == generation, !Task.isCancelled else { return }
                toast.show(error.localizedDescription, style: .error)
            }
        }
    }

    func loadMoreIfNeeded(current item: WorkshopItem) {
        guard mode == .online, let index = onlineItems.firstIndex(where: { $0.id == item.id }), index >= onlineItems.count - 6 else { return }
        search(reset: false)
    }

    // MARK: - Download / Apply

    func download(_ item: WorkshopItem, applyWhenDone: Bool = false) {
        guard item.type.isPlayable else {
            toast.show("「应用」类型的壁纸是 Windows 程序，无法在 macOS 上运行", style: .error)
            return
        }

        // 双向同步：在 Mac 上下载时同时订阅，Windows 上的 Wallpaper Engine 会自动获取
        if subscribeOnDownload, account.isLoggedIn, !subscribedIDs.contains(item.id) {
            setSubscribed(item, true, quiet: true)
        }
        enqueueDownloads([item], applyWhenDone: applyWhenDone)
    }

    private func persistDownloads() {
        if let data = try? JSONEncoder().encode(downloadJobs) {
            UserDefaults.standard.set(data, forKey: Keys.downloadJobs)
        }
    }

    private func enqueueDownloads(_ items: [WorkshopItem], applyWhenDone: Bool = false, automatic: Bool = false) {
        var jobs = downloadJobs
        // 只有最新的手动应用意图可以在下载结束后改变桌面。
        if applyWhenDone {
            for index in jobs.indices { jobs[index].applyWhenDone = false }
        }
        for item in items {
            if let index = jobs.firstIndex(where: { $0.id == item.id }) {
                if automatic { continue } // 同步不能自动恢复用户暂停、停止或失败的任务。
                if jobs[index].state != .downloading { jobs[index].state = .queued }
                jobs[index].error = nil
                jobs[index].applyWhenDone = applyWhenDone || jobs[index].applyWhenDone
            } else {
                jobs.append(WorkshopDownloadJob(id: item.id, title: item.title, state: .queued, applyWhenDone: applyWhenDone))
            }
        }
        downloadJobs = jobs
        processDownloadQueue()
    }

    /// 批次中的某个条目已下载完成：立即更新状态，不等整批结束
    fileprivate func markDownloaded(_ id: String) {
        guard let index = downloadJobs.firstIndex(where: { $0.id == id }), downloadJobs[index].state == .downloading else { return }
        downloadJobs[index].state = .completed
        downloadJobs[index].error = nil
        activeDownloads.remove(id)
        refreshLibrary()
    }

    private func processDownloadQueue() {
        guard !isProcessingQueue, !isShuttingDown else { return }
        // 同时下载数量：这一批标记为「下载中」，其余继续排队
        let batch = Array(downloadJobs.filter { $0.state == .queued }.prefix(maxConcurrentDownloads).map(\.id))
        guard !batch.isEmpty else { return }
        isProcessingQueue = true
        batchInterrupted = false
        activeDownloads = Set(batch)
        downloadJobs = downloadJobs.map {
            var job = $0
            if activeDownloads.contains(job.id) { job.state = .downloading }
            return job
        }
        Task {
            defer {
                activeDownloads = []
                isProcessingQueue = false
                processDownloadQueue()
            }
            let result: SteamCMDDownloader.BatchResult
            do {
                if batchInterrupted || isShuttingDown {
                    result = .init()
                } else {
                    let relay = DownloadProgressRelay(self)
                    result = try await SteamCMDDownloader.shared.download(ids: batch, username: steamUsername) { id in
                        relay.downloaded(id)
                    }
                }
            } catch {
                result = .init(failed: Dictionary(uniqueKeysWithValues: batch.map { ($0, error.localizedDescription) }))
            }
            for folder in result.downloaded.values {
                let root = folder.deletingLastPathComponent()
                if !libraryRoots.contains(where: { Self.pathKey($0) == Self.pathKey(root) }) {
                    setExtraFolders(extraFolders + [root])
                }
            }
            // 在等待扫描前结算任务，暂停/恢复仍可在扫描期间正常操作。
            let shouldApply = downloadJobs.first {
                $0.applyWhenDone && $0.state == .downloading && result.downloaded[$0.id] != nil
            }?.id
            downloadJobs = WorkshopDownloadQueue.settle(downloadJobs, batch: Set(batch),
                downloaded: Set(result.downloaded.keys), failures: result.failed, interrupted: batchInterrupted)
            if !batchInterrupted {
                let failed = downloadJobs.filter { batch.contains($0.id) && $0.state == .failed }
                if let first = failed.first {
                    toast.show("\(failed.count) 个壁纸下载失败：\(first.error ?? "下载未完成")", style: .error)
                } else {
                    toast.show("已下载 \(result.downloaded.count) 个壁纸", style: .success)
                }
            }
            await refreshLibraryAndWait()
            if let id = shouldApply,
               downloadJobs.contains(where: { $0.id == id && $0.state == .completed && $0.applyWhenDone }),
               let item = libraryItems.first(where: { $0.id == id }) {
                apply(item)
            }
            downloadJobs = downloadJobs.map {
                var job = $0
                if job.state == .completed { job.applyWhenDone = false }
                return job
            }
        }
    }

    func pauseDownload(_ id: String) { interruptDownload(id, state: .paused) }
    func cancelDownload(_ item: WorkshopItem) { cancelDownload(item.id) }
    func cancelDownload(_ id: String) { interruptDownload(id, state: .cancelled) }

    private func interruptDownload(_ id: String, state: DownloadState) {
        guard let index = downloadJobs.firstIndex(where: { $0.id == id }),
              [.queued, .downloading, .paused, .failed].contains(downloadJobs[index].state) else { return }
        downloadJobs[index].state = state
        downloadJobs[index].applyWhenDone = false
        downloadJobs[index].error = nil
        if activeDownloads.contains(id) {
            batchInterrupted = true
            SteamCMDDownloader.shared.cancel(id)
        }
    }

    func resumeDownload(_ id: String) {
        guard let index = downloadJobs.firstIndex(where: { $0.id == id }),
              [.paused, .failed, .cancelled].contains(downloadJobs[index].state) else { return }
        downloadJobs[index].state = .queued
        downloadJobs[index].error = nil
        processDownloadQueue()
    }

    func pauseAllDownloads() {
        downloadJobs = downloadJobs.map {
            var job = $0
            if job.state == .queued || job.state == .downloading {
                job.state = .paused
                job.applyWhenDone = false
            }
            return job
        }
        if !activeDownloads.isEmpty {
            batchInterrupted = true
            SteamCMDDownloader.shared.terminateAll()
        }
    }

    func resumeAllDownloads() {
        downloadJobs = downloadJobs.map {
            var job = $0
            if job.state == .paused { job.state = .queued; job.error = nil }
            return job
        }
        processDownloadQueue()
    }

    func cancelAllDownloads() {
        downloadJobs = downloadJobs.map {
            var job = $0
            if [.queued, .downloading, .paused, .failed].contains(job.state) {
                job.state = .cancelled
                job.applyWhenDone = false
                job.error = nil
            }
            return job
        }
        if !activeDownloads.isEmpty {
            batchInterrupted = true
            SteamCMDDownloader.shared.terminateAll()
        }
    }

    // MARK: - Subscriptions (two-way sync)

    /// 从 Steam 账号拉取订阅；force 为 false 时 10 分钟内不重复同步
    func syncSubscriptions(force: Bool = false) {
        guard !isSyncing else { return }
        if !force, let lastSyncAt, Date().timeIntervalSince(lastSyncAt) < 600 { return }
        isSyncing = true
        Task {
            defer { isSyncing = false }
            guard await account.refreshFromCookies() else { return }
            do {
                let list = try await account.subscriptions()
                let ids = list.entries.map(\.id)
                var fetched: [WorkshopItem] = []
                for start in stride(from: 0, to: ids.count, by: 100) {
                    fetched += try await api.details(ids: Array(ids[start..<min(start + 100, ids.count)]))
                }
                // 公开详情接口查不到的条目（被作者删除、隐藏或受限）用订阅页上的标题和预览图补上，保证不丢
                let byID = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let details = list.entries.map { entry in
                    byID[entry.id] ?? WorkshopItem(
                        id: entry.id,
                        title: entry.title ?? "工坊条目 \(entry.id)",
                        type: .unknown,
                        previewURL: entry.previewURL,
                        tags: []
                    )
                }
                let unavailable = list.entries.count - byID.count
                subscribedIDs = Set(ids)
                subscribedItems = details
                lastSyncAt = Date()
                mergeDownloadState()

                // Windows 上新订阅的壁纸自动下载到 Mac
                if autoDownloadSubscriptions {
                    let scanned = await refreshLibraryAndWait()
                    let localIDs = Set(scanned.map(\.id))
                    let missing = details.filter { !localIDs.contains($0.id) && $0.type.isPlayable }
                    if !missing.isEmpty { enqueueDownloads(missing, automatic: true) }
                }
                if force || unavailable > 0 {
                    var message = "已同步 \(ids.count) 个订阅"
                    if unavailable > 0 { message += "（\(unavailable) 个无法获取详情，可能已被作者删除或隐藏）" }
                    if let total = list.reportedTotal, total > ids.count { message += "，Steam 显示共 \(total) 个" }
                    toast.show(message, style: unavailable > 0 ? .info : .success)
                }
            } catch {
                toast.show("同步订阅失败：\(error.localizedDescription)", style: .error)
            }
        }
    }

    func toggleSubscription(_ item: WorkshopItem) {
        setSubscribed(item, !subscribedIDs.contains(item.id))
    }

    private func setSubscribed(_ item: WorkshopItem, _ subscribed: Bool, quiet: Bool = false) {
        guard account.isLoggedIn else {
            toast.show(SteamSessionError.notLoggedIn.localizedDescription, style: .error)
            return
        }
        // 先更新界面，失败再回滚（回滚时放回原来的位置）
        let originalIndex = subscribedItems.firstIndex { $0.id == item.id }
        if subscribed {
            subscribedIDs.insert(item.id)
            if originalIndex == nil { subscribedItems.insert(item, at: 0) }
        } else {
            subscribedIDs.remove(item.id)
            subscribedItems.removeAll { $0.id == item.id }
        }
        Task {
            do {
                if subscribed {
                    try await account.subscribe(item.id)
                } else {
                    try await account.unsubscribe(item.id)
                }
                if !quiet { toast.show(subscribed ? "已订阅「\(item.title)」" : "已取消订阅「\(item.title)」", style: .success) }
            } catch {
                if subscribed {
                    subscribedIDs.remove(item.id)
                    subscribedItems.removeAll { $0.id == item.id }
                } else {
                    subscribedIDs.insert(item.id)
                    if !subscribedItems.contains(where: { $0.id == item.id }) {
                        subscribedItems.insert(item, at: min(originalIndex ?? 0, subscribedItems.count))
                    }
                }
                toast.show("\(subscribed ? "订阅" : "取消订阅")失败：\(error.localizedDescription)", style: .error)
            }
        }
    }

    func logoutSteam() {
        Task {
            await account.logout()
            subscribedIDs = []
            subscribedItems = []
            lastSyncAt = nil
            if mode == .subscribed { mode = .library }
        }
    }

    func apply(_ item: WorkshopItem) {
        PlaylistManager.shared.userDidApplyManually()
        guard item.isDownloaded else {
            download(item, applyWhenDone: true)
            return
        }
        do {
            try LiveWallpaperController.shared.start(workshop: item)
            toast.show("动态壁纸已启用：\(item.title)", style: .success)
        } catch {
            toast.show(error.localizedDescription, style: .error)
        }
    }

    func openInSteam(_ item: WorkshopItem) {
        guard item.id.allSatisfy(\.isNumber) else { return }
        // 优先用 Steam 客户端打开工坊页面，可直接订阅
        if let steamURL = URL(string: "steam://url/CommunityFilePage/\(item.id)"),
           NSWorkspace.shared.urlForApplication(toOpen: steamURL) != nil {
            NSWorkspace.shared.open(steamURL)
        } else if let url = item.workshopPageURL {
            NSWorkspace.shared.open(url)
        }
    }

    func openAPIKeyPage() {
        NSWorkspace.shared.open(URL(string: "https://steamcommunity.com/dev/apikey")!)
    }

    func loginSteamCMD() {
        do {
            try SteamCMDDownloader.openLoginInTerminal(username: steamUsername)
        } catch {
            toast.show(error.localizedDescription, style: .error)
        }
    }
}

/// 把 steamcmd 输出线程上的「单个条目下载完成」转发回主线程
nonisolated private final class DownloadProgressRelay: @unchecked Sendable {
    private weak var target: WorkshopViewModel?

    init(_ target: WorkshopViewModel) {
        self.target = target
    }

    func downloaded(_ id: String) {
        let target = self.target
        Task { @MainActor in target?.markDownloaded(id) }
    }
}
