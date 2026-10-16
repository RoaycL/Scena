//
//  WorkshopViewModel.swift
//  wallhaven
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// steamcmd 的登录状态
enum SteamCMDStatus: Equatable {
    case notInstalled
    case noUsername
    /// 没有缓存的登录凭据
    case notLoggedIn
    /// 有缓存的凭据（尚未通过下载或验证确认）
    case cached
    /// 最近一次下载或验证成功
    case verified
    /// 凭据已失效（下载或验证时提示未登录）
    case expired
    case verifying
}

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
    /// 重新搜索（换关键词、筛选）中：旧结果保留并变暗，新结果到了再整体替换，不会先清空成一片空白
    @Published private(set) var isRefreshing = false
    @Published private(set) var downloadJobs: [WorkshopDownloadJob] = [] {
        didSet { persistDownloads() }
    }
    /// 正在退出的批次也保留在这里，确保恢复操作不会启动第二个进程。
    @Published private(set) var activeDownloads: Set<String> = []
    /// 下载进度单独发布，避免每秒刷新整个主界面
    let progress = WorkshopDownloadProgress()

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
    /// 每批下载数量（每次 steamcmd 登录处理的条目数，批内逐个下载），超出的排队等待
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

    @Published var query = "" { didSet { UserDefaults.standard.set(query, forKey: Keys.query) } }
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
        didSet {
            UserDefaults.standard.set(steamUsername, forKey: Keys.username)
            refreshSteamCMDStatus()
        }
    }
    @Published private(set) var extraFolders: [URL]
    @Published private(set) var steamCMDStatus: SteamCMDStatus = .notLoggedIn

    private enum Keys {
        static let apiKey = "workshop.steamWebAPIKey"
        static let username = "workshop.steamUsername"
        static let folders = "workshop.libraryFolders"
        static let query = "workshop.searchQuery"
        static let filters = "workshop.filters"
        static let subscribeOnDownload = "workshop.subscribeOnDownload"
        static let downloadReceipts = "workshop.downloadReceipts.v1"
        static let downloadJobs = "workshop.downloadJobs.v1"
        static let autoDownload = "workshop.autoDownloadSubscriptions"
        static let maxConcurrentDownloads = "workshop.maxConcurrentDownloads"
        /// 已经提示过「无法获取详情」的订阅：同一批失败不会每次后台同步都提示
        static let notifiedUnavailable = "workshop.notifiedUnavailableSubscriptions"
        /// 记录凭据失效时对应的用户名，重新登录（凭据变化）前一直显示「已失效」
        static let steamCMDExpiredUser = "workshop.steamcmdExpiredUser"
        static let steamCMDExpiredAt = "workshop.steamcmdExpiredAt"
    }

    private var downloadReceipts: [String: WorkshopDownloadReceipt] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(downloadReceipts) {
                UserDefaults.standard.set(data, forKey: Keys.downloadReceipts)
            }
        }
    }
    /// 用户点了「重试」的条目：即使本地文件看起来完整也交给 Steam 重新校验
    private var forcedValidation: Set<String> = []
    private let api = SteamWorkshopAPI()
    private let toast = ToastCenter.shared
    /// 在线浏览的翻页状态。多选题材时每个题材单独查询（题材之间是「任选其一」，
    /// Steam 一次请求只能整体选「全部满足」或「任一满足」），key 是题材标签；单个查询的 key 是空字符串
    private var pageStates: [String: OnlinePageState] = [:]
    /// 在线浏览是否还有下一页（网格底部据此显示「加载更多」或「已经到底了」）
    @Published private(set) var canLoadMore = true
    /// 连续几页去重后没有新条目：自动再拉下一页，避免停在底部没有新格子出现、再也不触发加载
    private var emptyPageStreak = 0
    private var searchGeneration = UUID()
    private var libraryGeneration = UUID()
    private var searchTask: Task<Void, Never>?
    private var filterDebounce: Task<Void, Never>?
    private let account = SteamAccountSession.shared
    private var accountObserver: AnyCancellable?
    private var subscriptionSyncTask: Task<Void, Never>?
    private var subscriptionGeneration = UUID()
    /// 下载队列：串行执行，每批最多 10 个条目共用一次 steamcmd 登录
    private var batchInterrupted = false
    private var isProcessingQueue = false
    private var storageObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var isShuttingDown = false

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.downloadReceipts),
           let saved = try? JSONDecoder().decode([String: WorkshopDownloadReceipt].self, from: data) {
            downloadReceipts = saved
        }
        query = defaults.string(forKey: Keys.query) ?? ""
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
        Task { await completeJobsAlreadyOnDisk() }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isShuttingDown = true
                self?.pauseAllDownloads()
            }
        }
        storageObserver = NotificationCenter.default.addObserver(forName: .storageLocationDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLibrary() }
        }
        // 在终端登录 steamcmd 后切回 App 时刷新状态
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSteamCMDStatus() }
        }
        refreshSteamCMDStatus()
        accountObserver = account.$steamID.removeDuplicates().dropFirst().sink { [weak self] id in
            guard let self else { return }
            resetAccountSubscriptions()
            if let id {
                Task { [weak self] in
                    guard let self, account.steamID == id else { return }
                    syncSubscriptions(force: true)
                }
            }
        }
    }

    // MARK: - steamcmd login status

    /// 只读取本地状态，不登录 Steam
    func refreshSteamCMDStatus() {
        guard steamCMDStatus != .verifying else { return }
        let username = steamUsername.trimmingCharacters(in: .whitespaces)
        if steamCMDPath == nil {
            steamCMDStatus = .notInstalled
        } else if username.isEmpty {
            steamCMDStatus = .noUsername
        } else if UserDefaults.standard.string(forKey: Keys.steamCMDExpiredUser) == username.lowercased(), !credentialsChangedSinceExpiry {
            steamCMDStatus = .expired
        } else if steamCMDStatus == .verified {
            return
        } else {
            steamCMDStatus = SteamCMDDownloader.hasCachedCredentials(username: username) ? .cached : .notLoggedIn
        }
    }

    /// 失效后在终端重新登录会改写凭据文件：文件比失效时间新，就不再显示「已失效」
    private var credentialsChangedSinceExpiry: Bool {
        guard let expiredAt = UserDefaults.standard.object(forKey: Keys.steamCMDExpiredAt) as? Date else { return false }
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/config/config.vdf")
        guard let modified = (try? config.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return false }
        return modified > expiredAt
    }

    /// 用缓存的凭据实际登录一次确认是否有效（用户点击「验证」时）
    func verifySteamCMDLogin() {
        guard steamCMDStatus != .verifying, !SteamCMDDownloader.shared.isBusy else {
            toast.show("正在下载，稍后再验证", style: .info)
            return
        }
        steamCMDStatus = .verifying
        Task {
            let ok = (try? await SteamCMDDownloader.shared.verifyLogin(username: steamUsername)) ?? false
            steamCMDStatus = .notLoggedIn
            setSteamCMDLogin(valid: ok)
            toast.show(ok ? "steamcmd 登录有效" : "steamcmd 登录已失效，请在终端重新登录", style: ok ? .success : .error)
        }
    }

    private func setSteamCMDLogin(valid: Bool) {
        let username = steamUsername.trimmingCharacters(in: .whitespaces).lowercased()
        if valid {
            UserDefaults.standard.removeObject(forKey: Keys.steamCMDExpiredUser)
            UserDefaults.standard.removeObject(forKey: Keys.steamCMDExpiredAt)
            steamCMDStatus = .verified
        } else {
            UserDefaults.standard.set(username, forKey: Keys.steamCMDExpiredUser)
            // 稍微往后放一点，避免失败的这次登录本身改写凭据文件导致马上被判定为「已重新登录」
            UserDefaults.standard.set(Date().addingTimeInterval(5), forKey: Keys.steamCMDExpiredAt)
            steamCMDStatus = .expired
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
        if libraryItems.isEmpty {
            let cached = await WorkshopLibraryIndex.shared.cachedItems(roots: roots)
            if libraryGeneration == generation, roots == libraryRoots, !cached.isEmpty { libraryItems = cached }
        }
        let scanned = await WorkshopLibraryIndex.shared.scan(roots: roots)
        // 扫描被取消时返回空数组（例如切换 Steam 账号取消订阅同步），不能当成资料库已清空
        guard !Task.isCancelled else { return libraryItems }
        guard roots == libraryRoots else { return await refreshLibraryAndWait() }
        if libraryGeneration == generation {
            if libraryItems != scanned { libraryItems = scanned }
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
        // 内容没变时不重新赋值：每次发布都会重建主界面，打开中的右键菜单会被关闭
        let online = onlineItems.map(merge)
        if online != onlineItems { onlineItems = online }
        let subscribed = subscribedItems.map(merge)
        if subscribed != subscribedItems { subscribedItems = subscribed }
    }

    /// 移到废纸篓；unsubscribe 为 true 时同时取消 Steam 订阅（Windows 上也会移除）
    func delete(_ item: WorkshopItem, unsubscribe: Bool = false) {
        if unsubscribe { setSubscribed(item, false) }
        guard let folder = item.localFolder else { return }
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: folder, resultingItemURL: &trashed)
            if LiveWallpaperController.shared.currentURL?.standardizedFileURL == folder.standardizedFileURL {
                LiveWallpaperController.shared.stop()
            }
            libraryItems.removeAll { $0.id == item.id }
            mergeDownloadState()
            toast.show(unsubscribe ? "已移到废纸篓并取消订阅" : "已移到废纸篓", style: .info, actionTitle: "撤销") { [weak self] in
                self?.restoreFromTrash(trashed as URL?, to: folder, item: item, resubscribe: unsubscribe)
            }
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
            pageStates = [:]
            canLoadMore = true
            emptyPageStreak = 0
            isRefreshing = true
        }
        guard canLoadMore, !isLoading else { return }
        let replacing = reset

        let generation = searchGeneration
        let requestQuery = query
        let requestFilters = filters
        let requestKey = apiKey.trimmingCharacters(in: .whitespaces)
        let groups = OnlinePageState.groups(for: requestFilters)
        let requestStates = groups.map { (group: $0, state: pageStates[$0] ?? OnlinePageState()) }.filter { !$0.state.isDone }
        isLoading = true
        searchTask = Task {
            defer {
                if searchGeneration == generation {
                    isLoading = false
                    isRefreshing = false
                }
            }
            do {
                let newItems: [WorkshopItem]
                var nextStates: [String: OnlinePageState] = [:]
                if isIDLookup {
                    newItems = try await api.details(ids: ids)
                    nextStates[""] = OnlinePageState(isDone: true)
                } else {
                    // 各题材并行取下一页，结果交错合并
                    let api = self.api
                    let pages = try await withThrowingTaskGroup(of: (Int, String, [WorkshopItem], OnlinePageState).self) { group in
                        for (index, entry) in requestStates.enumerated() {
                            var groupFilters = requestFilters
                            if !entry.group.isEmpty { groupFilters.genres = [entry.group] }
                            group.addTask {
                                var state = entry.state
                                let items: [WorkshopItem]
                                if !requestKey.isEmpty {
                                    // 有 API Key：官方 QueryFiles 接口，更快更稳定
                                    let page = try await api.query(apiKey: requestKey, text: requestQuery, filters: groupFilters, cursor: state.cursor)
                                    items = page.items
                                    state.isDone = page.nextCursor == nil || page.nextCursor == state.cursor
                                    state.cursor = page.nextCursor
                                } else {
                                    // 无 API Key：解析工坊网页
                                    items = try await api.browseWeb(text: requestQuery, filters: groupFilters, page: state.page)
                                    state.page += 1
                                    state.isDone = items.isEmpty
                                }
                                return (index, entry.group, items, state)
                            }
                        }
                        var results: [(Int, String, [WorkshopItem], OnlinePageState)] = []
                        for try await result in group { results.append(result) }
                        return results.sorted { $0.0 < $1.0 }
                    }
                    for page in pages { nextStates[page.1] = page.3 }
                    newItems = OnlinePageState.interleave(pages.map(\.2))
                }
                guard searchGeneration == generation, !Task.isCancelled else { return }
                pageStates.merge(nextStates) { _, new in new }
                let hasMore = isIDLookup ? false : groups.contains { !(pageStates[$0]?.isDone ?? false) }
                if canLoadMore != hasMore { canLoadMore = hasMore }
                var existing = replacing ? [] : Set(onlineItems.map(\.id))
                let fresh = newItems.filter { existing.insert($0.id).inserted }
                if replacing { onlineItems = fresh } else { onlineItems.append(contentsOf: fresh) }
                mergeDownloadState()
                if fresh.isEmpty && hasMore && emptyPageStreak < 3 {
                    emptyPageStreak += 1
                    // 等 defer 把 isLoading 复位后再请求下一页
                    Task { @MainActor in self.search(reset: false) }
                } else {
                    emptyPageStreak = 0
                }
            } catch {
                guard searchGeneration == generation, !Task.isCancelled else { return }
                toast.show(error.localizedDescription, style: .error)
            }
        }
    }

    // MARK: - Detail info

    private var extraInfoCache: [String: SteamWorkshopAPI.ExtraInfo] = [:]

    /// 详情栏的简介、作者、评分（按条目缓存）。本地导入、没有工坊 ID 的条目读 project.json 里的简介
    func extraInfo(for item: WorkshopItem) async -> SteamWorkshopAPI.ExtraInfo? {
        if let cached = extraInfoCache[item.id] { return cached }
        var info: SteamWorkshopAPI.ExtraInfo?
        if item.workshopPageURL != nil {
            info = try? await api.extraInfo(id: item.id, apiKey: apiKey)
        }
        if info == nil || info?.description.isEmpty == true, let folder = item.localFolder {
            let local = await Task.detached { () -> String? in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("project.json")),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return json["description"] as? String
            }.value
            if let local, !local.isEmpty {
                var merged = info ?? SteamWorkshopAPI.ExtraInfo()
                merged.description = SteamWorkshopAPI.plainText(fromBBCode: local)
                info = merged
            }
        }
        if let info { extraInfoCache[item.id] = info }
        return info
    }

    /// 网格滑到底部时调用
    func loadMore() {
        guard mode == .online else { return }
        search(reset: false)
    }

    func loadMoreIfNeeded(current item: WorkshopItem) {
        // 剩下约 3 行时就预加载
        guard mode == .online, let index = onlineItems.firstIndex(where: { $0.id == item.id }), index >= onlineItems.count - 15 else { return }
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
                if [.failed, .cancelled].contains(jobs[index].state) {
                    downloadReceipts[item.id] = nil
                    forcedValidation.insert(item.id)
                }
                if jobs[index].state != .downloading { jobs[index].state = .queued }
                jobs[index].error = nil
                jobs[index].applyWhenDone = applyWhenDone || jobs[index].applyWhenDone
            } else {
                jobs.append(WorkshopDownloadJob(id: item.id, title: item.title, state: .queued, applyWhenDone: applyWhenDone,
                                                totalBytes: item.fileSize > 0 ? Int64(item.fileSize) : nil))
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
        if downloadJobs[index].applyWhenDone || pendingPlaylistAdds[id] != nil {
            // 「下载并应用」「下载并添加到播放列表」：这一个下载完就立即处理，不等整批结束
            Task {
                await refreshLibraryAndWait()
                applyIfRequested(id)
                addToPendingPlaylists(id)
            }
        } else {
            scheduleLibraryRefresh()
        }
    }

    /// 未下载的工坊壁纸选择了「下载并添加到播放列表」：下载完成后加入这些列表
    private var pendingPlaylistAdds: [String: [UUID]] = [:]

    func downloadAndAddToPlaylist(_ item: WorkshopItem, playlistID: UUID) {
        guard item.type.isPlayable else {
            toast.show("「应用」类型的壁纸是 Windows 程序，无法在 macOS 上运行", style: .error)
            return
        }
        if !(pendingPlaylistAdds[item.id]?.contains(playlistID) ?? false) {
            pendingPlaylistAdds[item.id, default: []].append(playlistID)
        }
        download(item)
        let name = PlaylistManager.shared.playlists.first { $0.id == playlistID }?.name ?? "播放列表"
        toast.show("正在下载，完成后加入「\(name)」", style: .progress)
    }

    private func addToPendingPlaylists(_ id: String) {
        guard let playlistIDs = pendingPlaylistAdds[id],
              let item = libraryItems.first(where: { $0.id == id }),
              let entry = PlaylistEntry(GalleryItem(origin: .workshop(item))) else { return }
        pendingPlaylistAdds[id] = nil
        for playlistID in playlistIDs { PlaylistManager.shared.add([entry], to: playlistID) }
    }

    /// 下载完成且用户点过「下载并应用」的条目：应用一次并清除这个意图
    private func applyIfRequested(_ id: String) {
        guard let index = downloadJobs.firstIndex(where: { $0.id == id }),
              downloadJobs[index].state == .completed, downloadJobs[index].applyWhenDone,
              let item = libraryItems.first(where: { $0.id == id }), item.isDownloaded else { return }
        downloadJobs[index].applyWhenDone = false
        apply(item)
    }

    /// 一批里多个条目接连完成时合并成一次扫描，避免每完成一个就重扫整个资料库、刷新整个界面
    private var pendingLibraryRefresh: Task<Void, Never>?
    private func scheduleLibraryRefresh() {
        pendingLibraryRefresh?.cancel()
        pendingLibraryRefresh = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await refreshLibraryAndWait()
        }
    }

    /// steamcmd 下载中的临时目录：<安装目录>/steamapps/workshop/downloads/431960/<id>
    private static var stagingFolder: URL {
        let content = StorageManager.shared.workshopContentFolder // …/steamapps/workshop/content/431960
        return content.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("downloads", isDirectory: true)
            .appendingPathComponent(WorkshopConstants.appID, isDirectory: true)
    }

    /// 排队 / 暂停的任务如果本地已经完整，直接标记完成，不再让 steamcmd 重新校验、重写整个文件夹。
    /// 完整的判断：
    ///  - 有下载成功记录（receipt）且文件清单没变；或者
    ///  - 没有记录的旧壁纸：project.json 指向的入口文件存在且非空，并且 steamcmd 临时目录里没有它（没在下载中）。
    ///    确认后补一份记录，之后按记录判断
    /// 用户点「重试」的条目（forcedValidation）总是交给 Steam 校验。
    private func completeJobsAlreadyOnDisk() async {
        let candidates = downloadJobs
            .filter { [.queued, .paused].contains($0.state) && !forcedValidation.contains($0.id) }
            .map { ($0.id, downloadReceipts[$0.id]) }
        guard !candidates.isEmpty else { return }
        let roots = libraryRoots
        let staging = Self.stagingFolder
        // 逐个文件比对可能较慢（大壁纸、外接盘），放到后台
        let complete = await Task.detached(priority: .utility) {
            Self.completedOnDisk(candidates, roots: roots, staging: staging)
        }.value
        guard !complete.isEmpty else { return }
        for (id, receipt) in complete { downloadReceipts[id] = receipt }
        // 检查期间用户可能暂停 / 停止 / 要求重试，只更新状态仍然符合的任务
        downloadJobs = downloadJobs.map { job in
            guard complete[job.id] != nil, [.queued, .paused].contains(job.state),
                  !forcedValidation.contains(job.id) else { return job }
            var completed = job
            completed.state = .completed
            completed.error = nil
            // 保留应用意图，由本地素材关联完成后处理。
            return completed
        }
    }

    nonisolated private static func completedOnDisk(_ candidates: [(String, WorkshopDownloadReceipt?)],
                                                    roots: [URL], staging: URL) -> [String: WorkshopDownloadReceipt] {
        let fm = FileManager.default
        var result: [String: WorkshopDownloadReceipt] = [:]
        for (id, receipt) in candidates {
            for root in roots {
                let folder = root.appendingPathComponent(id)
                if let receipt {
                    if receipt.matches(folder: folder) { result[id] = receipt; break }
                } else if !fm.fileExists(atPath: staging.appendingPathComponent(id).path),
                          let captured = WorkshopDownloadReceipt.capture(folder: folder) {
                    result[id] = captured
                    break
                }
            }
        }
        return result
    }

    private func processDownloadQueue() {
        guard !isProcessingQueue, !isShuttingDown else { return }
        isProcessingQueue = true
        Task {
            // 已经在本地的条目不再交给 steamcmd（否则会重新校验、重写整个文件夹）
            await completeJobsAlreadyOnDisk()
            isProcessingQueue = false
            startNextBatch()
        }
    }

    private func startNextBatch() {
        guard !isProcessingQueue, !isShuttingDown else { return }
        // 每批数量：这一批标记为「下载中」，其余继续排队
        let batch = Array(downloadJobs.filter { $0.state == .queued }.prefix(maxConcurrentDownloads).map(\.id))
        if let job = downloadJobs.first(where: { $0.state == .completed && $0.applyWhenDone }),
           let item = libraryItems.first(where: { $0.id == job.id }) {
            if let index = downloadJobs.firstIndex(where: { $0.id == job.id }) { downloadJobs[index].applyWhenDone = false }
            apply(item)
        }
        guard !batch.isEmpty else { return }
        isProcessingQueue = true
        batchInterrupted = false
        activeDownloads = Set(batch)
        downloadJobs = downloadJobs.map {
            var job = $0
            if activeDownloads.contains(job.id) { job.state = .downloading }
            return job
        }
        // 文件大小：优先用任务里记录的，没有时从订阅 / 在线 / 本地条目里找
        let known = Dictionary((subscribedItems + onlineItems).filter { $0.fileSize > 0 }.map { ($0.id, Int64($0.fileSize)) },
                               uniquingKeysWith: { a, _ in a })
        let sizes = Dictionary(batch.compactMap { id in
            (downloadJobs.first { $0.id == id }?.totalBytes ?? known[id]).map { (id, $0) }
        }, uniquingKeysWith: { a, _ in a })
        progress.start(ids: batch, totalBytes: sizes, stagingFolder: Self.stagingFolder)
        Task {
            defer {
                progress.stop()
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
                if case SteamCMDError.notLoggedIn = error { setSteamCMDLogin(valid: false) }
                result = .init(failed: Dictionary(uniqueKeysWithValues: batch.map { ($0, error.localizedDescription) }))
            }
            if !result.downloaded.isEmpty { setSteamCMDLogin(valid: true) }
            for (id, folder) in result.downloaded {
                await WorkshopLibraryIndex.shared.invalidate(folder: folder)
                if let video = WorkshopItem.load(from: folder, computeSize: false)?.nativeVideoURL {
                    Task(priority: .utility) { await VideoPosterCache.shared.prewarm([video]) }
                }
                if let receipt = await Task.detached(priority: .utility, operation: {
                    WorkshopDownloadReceipt.capture(folder: folder)
                }).value {
                    downloadReceipts[id] = receipt
                }
                let root = folder.deletingLastPathComponent()
                if !libraryRoots.contains(where: { Self.pathKey($0) == Self.pathKey(root) }) {
                    setExtraFolders(extraFolders + [root])
                }
            }
            // 在等待扫描前结算任务，暂停/恢复仍可在扫描期间正常操作。
            // 批次中途已完成的条目状态已经是 completed，也要算进来
            let shouldApply = downloadJobs.first {
                $0.applyWhenDone && [.downloading, .completed].contains($0.state) && result.downloaded[$0.id] != nil
            }?.id
            downloadJobs = WorkshopDownloadQueue.settle(downloadJobs, batch: Set(batch),
                downloaded: Set(result.downloaded.keys), failures: result.failed, interrupted: batchInterrupted)
            forcedValidation.subtract(result.downloaded.keys)
            if !batchInterrupted {
                let failed = downloadJobs.filter { batch.contains($0.id) && $0.state == .failed }
                if let first = failed.first {
                    toast.show("\(failed.count) 个壁纸下载失败：\(first.error ?? "下载未完成")", style: .error)
                } else {
                    toast.show("已下载 \(result.downloaded.count) 个壁纸", style: .success)
                }
            }
            await refreshLibraryAndWait()
            if let id = shouldApply { applyIfRequested(id) }
            for id in result.downloaded.keys { addToPendingPlaylists(id) }
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
        // 失败 / 停止后重试：强制重新校验；暂停后恢复：本地已完整就直接完成
        if downloadJobs[index].state != .paused {
            downloadReceipts[id] = nil
            forcedValidation.insert(id)
        }
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

    /// 从列表中移除已完成和已停止的任务
    func clearFinishedDownloads() {
        downloadJobs.removeAll { $0.state == .completed || $0.state == .cancelled }
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
        let operation = UUID()
        subscriptionGeneration = operation
        subscriptionSyncTask = Task {
            defer { if subscriptionGeneration == operation { isSyncing = false; subscriptionSyncTask = nil } }
            guard await account.ensureAuthenticated(), !Task.isCancelled else { return }
            let accountEpoch = account.sessionIdentifier
            do {
                let list = try await account.subscriptions()
                let ids = list.entries.map(\.id)
                var fetched: [WorkshopItem] = []
                for start in stride(from: 0, to: ids.count, by: 100) {
                    try Task.checkCancellation()
                    fetched += try await api.details(ids: Array(ids[start..<min(start + 100, ids.count)]))
                }
                guard !Task.isCancelled, subscriptionGeneration == operation,
                      account.sessionIdentifier == accountEpoch else { return }
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
                subscribedIDs = Set(ids)
                subscribedItems = details
                lastSyncAt = Date()
                mergeDownloadState()

                // Windows 上新订阅的壁纸自动下载到 Mac
                if autoDownloadSubscriptions {
                    let scanned = await refreshLibraryAndWait()
                    guard !Task.isCancelled, subscriptionGeneration == operation,
                          account.sessionIdentifier == accountEpoch else { return }
                    let localIDs = Set(scanned.map(\.id))
                    let missing = details.filter { !localIDs.contains($0.id) && $0.type.isPlayable }
                    if !missing.isEmpty { enqueueDownloads(missing, automatic: true) }
                }
                // 静默同步：全部成功不提示。有条目查不到详情时提示一次（点击跳到第一个），
                // 之后同一批失败只在手动同步时再提示
                let unavailableIDs = ids.filter { byID[$0] == nil }
                let notified = Set(UserDefaults.standard.stringArray(forKey: Keys.notifiedUnavailable) ?? [])
                if let first = unavailableIDs.first, force || !Set(unavailableIDs).isSubset(of: notified) {
                    let message = unavailableIDs.count == 1
                        ? "订阅「\(details.first { $0.id == first }?.title ?? first)」无法获取详情，可能已被作者删除或隐藏"
                        : "\(unavailableIDs.count) 个订阅无法获取详情，可能已被作者删除或隐藏"
                    toast.show(message, style: .info) { MainWindow.reveal(subscribedWorkshopItemID: first) }
                }
                UserDefaults.standard.set(unavailableIDs, forKey: Keys.notifiedUnavailable)
            } catch {
                guard !Task.isCancelled, subscriptionGeneration == operation,
                      account.sessionIdentifier == accountEpoch else { return }
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
        let accountEpoch = account.sessionIdentifier
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
                guard account.sessionIdentifier == accountEpoch else { return }
                if !quiet { toast.show(subscribed ? "已订阅「\(item.title)」" : "已取消订阅「\(item.title)」", style: .success) }
            } catch {
                guard account.sessionIdentifier == accountEpoch, !Task.isCancelled else { return }
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
        resetAccountSubscriptions()
        Task {
            await account.logout()
            subscribedIDs = []
            subscribedItems = []
            lastSyncAt = nil
            if mode == .subscribed { mode = .library }
        }
    }

    private func resetAccountSubscriptions() {
        subscriptionGeneration = UUID()
        subscriptionSyncTask?.cancel()
        subscriptionSyncTask = nil
        isSyncing = false
        subscribedIDs = []
        subscribedItems = []
        lastSyncAt = nil
    }

    /// 撤销删除：文件夹从废纸篓移回，删除时一起取消的订阅也恢复
    private func restoreFromTrash(_ trashed: URL?, to folder: URL, item: WorkshopItem, resubscribe: Bool) {
        do {
            guard let trashed else { throw CocoaError(.fileNoSuchFile) }
            try FileManager.default.moveItem(at: trashed, to: folder)
            if resubscribe { setSubscribed(item, true, quiet: true) }
            refreshLibrary()
        } catch {
            toast.show("无法恢复：文件夹已不在废纸篓中", style: .error)
        }
    }

    func apply(_ item: WorkshopItem) {
        PlaylistManager.shared.userDidApplyManually()
        guard item.isDownloaded else {
            download(item, applyWhenDone: true)
            return
        }
        let feedbackID = GalleryItem(origin: .workshop(item)).id
        ApplyFeedback.shared.begin(feedbackID)
        do {
            try LiveWallpaperController.shared.start(workshop: item)
            // 成功反馈在「设为壁纸」按钮上，不再弹提示条
            ApplyFeedback.shared.finish(feedbackID, success: true)
        } catch {
            ApplyFeedback.shared.finish(feedbackID, success: false)
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

/// 当前批次的下载进度。steamcmd 一次只下载一个条目，先写到 downloads 临时目录，完成后再移到 content，
/// 所以按临时目录的大小估算进度；有临时目录的就是正在下载的条目
final class WorkshopDownloadProgress: ObservableObject {
    struct Entry: Equatable {
        var bytes: Int64
        var total: Int64?

        var fraction: Double? {
            guard let total, total > 0 else { return nil }
            return min(1, Double(bytes) / Double(total))
        }
    }

    @Published private(set) var entries: [String: Entry] = [:]
    /// 当前下载速度（字节 / 秒）
    @Published private(set) var bytesPerSecond: Int64 = 0
    /// 本批次中还在等待 steamcmd 处理的条目
    @Published private(set) var batch: Set<String> = []

    private var task: Task<Void, Never>?

    func start(ids: [String], totalBytes: [String: Int64], stagingFolder: URL) {
        task?.cancel()
        batch = Set(ids)
        entries = [:]
        bytesPerSecond = 0
        task = Task { [weak self] in
            var lastTotal: Int64?
            while !Task.isCancelled {
                let sizes = await Task.detached { Self.sizes(of: ids, in: stagingFolder) }.value
                guard !Task.isCancelled, let self else { return }
                let next = sizes.reduce(into: [String: Entry]()) { result, pair in
                    result[pair.key] = Entry(bytes: pair.value, total: totalBytes[pair.key])
                }
                if next != self.entries { self.entries = next }
                let total = sizes.values.reduce(0, +)
                if let lastTotal { self.bytesPerSecond = max(0, total - lastTotal) }
                lastTotal = total
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        entries = [:]
        batch = []
        bytesPerSecond = 0
    }

    nonisolated private static func sizes(of ids: [String], in folder: URL) -> [String: Int64] {
        let fm = FileManager.default
        var result: [String: Int64] = [:]
        for id in ids {
            let url = folder.appendingPathComponent(id, isDirectory: true)
            guard fm.fileExists(atPath: url.path) else { continue }
            var total: Int64 = 0
            if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
                // 用实际占用的空间：steamcmd 可能预先创建完整大小的文件
                for case let file as URL in enumerator {
                    total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
                }
            }
            result[id] = total
        }
        return result
    }
}

/// 在线浏览某一组查询的翻页进度
nonisolated struct OnlinePageState: Sendable, Equatable {
    var cursor: String?
    var page = 1
    var isDone = false

    /// 多选题材时每个题材一组，否则只有一组（空字符串）
    static func groups(for filters: WorkshopFilters) -> [String] {
        let genres = filters.genres.filter { $0 != "Anime" }.sorted()
        return genres.count > 1 ? genres : [""]
    }

    /// 轮流从每组取一个，保持各题材均匀出现
    static func interleave(_ lists: [[WorkshopItem]]) -> [WorkshopItem] {
        var result: [WorkshopItem] = []
        let longest = lists.map(\.count).max() ?? 0
        for index in 0..<longest {
            for list in lists where index < list.count { result.append(list[index]) }
        }
        return result
    }
}
