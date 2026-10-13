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
    /// 排队中 + 正在下载
    @Published private(set) var downloading: Set<String> = []

    // 订阅同步
    @Published private(set) var subscribedIDs: Set<String> = []
    @Published private(set) var subscribedItems: [WorkshopItem] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncAt: Date?
    @Published var subscribeOnDownload: Bool {
        didSet { UserDefaults.standard.set(subscribeOnDownload, forKey: Keys.subscribeOnDownload) }
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
        static let autoDownload = "workshop.autoDownloadSubscriptions"
    }

    private let api = SteamWorkshopAPI()
    private let toast = ToastCenter.shared
    private var cursor: String?
    private var webPage = 1
    private var canLoadMore = true
    private var searchTask: Task<Void, Never>?
    private var filterDebounce: Task<Void, Never>?
    private let account = SteamAccountSession.shared
    /// 下载队列：串行执行，每批最多 10 个条目共用一次 steamcmd 登录
    private var downloadQueue: [String] = []
    private var applyAfterDownload: String?
    private var isProcessingQueue = false

    init() {
        let defaults = UserDefaults.standard
        apiKey = defaults.string(forKey: Keys.apiKey) ?? ""
        steamUsername = defaults.string(forKey: Keys.username) ?? ""
        filters = defaults.data(forKey: Keys.filters).flatMap { try? JSONDecoder().decode(WorkshopFilters.self, from: $0) } ?? WorkshopFilters()
        extraFolders = (defaults.stringArray(forKey: Keys.folders) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        subscribeOnDownload = defaults.object(forKey: Keys.subscribeOnDownload) as? Bool ?? true
        autoDownloadSubscriptions = defaults.object(forKey: Keys.autoDownload) as? Bool ?? true
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
            filters.genres = [tag]
        } else {
            query = tag
            if mode == .online { search(reset: true) }
        }
    }

    /// 本地库根目录：Steam / steamcmd 默认下载目录 + 用户添加的文件夹
    var libraryRoots: [URL] {
        [WorkshopLibrary.steamContentFolder] + extraFolders
    }

    // MARK: - Library

    func refreshLibrary() {
        let roots = libraryRoots
        Task {
            let items = await Task.detached { WorkshopLibrary.scan(roots: roots) }.value
            libraryItems = items
            mergeDownloadState()
        }
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
            isLoading = false
            cursor = nil
            webPage = 1
            canLoadMore = true
            onlineItems = []
        }
        guard canLoadMore, !isLoading else { return }

        isLoading = true
        searchTask = Task {
            do {
                let newItems: [WorkshopItem]
                if isIDLookup {
                    newItems = try await api.details(ids: ids)
                    canLoadMore = false
                } else if hasAPIKey {
                    // 有 API Key：官方 QueryFiles 接口，更快更稳定
                    let page = try await api.query(
                        apiKey: apiKey.trimmingCharacters(in: .whitespaces),
                        text: query,
                        filters: filters,
                        cursor: cursor
                    )
                    newItems = page.items
                    canLoadMore = page.nextCursor != nil && page.nextCursor != cursor
                    cursor = page.nextCursor
                } else {
                    // 无 API Key：解析工坊网页
                    newItems = try await api.browseWeb(
                        text: query,
                        filters: filters,
                        page: webPage
                    )
                    webPage += 1
                    canLoadMore = !newItems.isEmpty
                }
                guard !Task.isCancelled else { return }
                let existing = Set(onlineItems.map(\.id))
                onlineItems.append(contentsOf: newItems.filter { !existing.contains($0.id) })
                mergeDownloadState()
            } catch {
                guard !Task.isCancelled else { return }
                toast.show(error.localizedDescription, style: .error)
            }
            if !Task.isCancelled { isLoading = false }
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
        if applyWhenDone { applyAfterDownload = item.id }
        // 双向同步：在 Mac 上下载时同时订阅，Windows 上的 Wallpaper Engine 会自动获取
        if subscribeOnDownload, account.isLoggedIn, !subscribedIDs.contains(item.id) {
            setSubscribed(item, true, quiet: true)
        }
        enqueueDownloads([item.id])
    }

    private func enqueueDownloads(_ ids: [String]) {
        let fresh = ids.filter { !downloading.contains($0) }
        guard !fresh.isEmpty else { return }
        downloadQueue += fresh
        downloading.formUnion(fresh)
        processDownloadQueue()
    }

    private func processDownloadQueue() {
        guard !isProcessingQueue, !downloadQueue.isEmpty else { return }
        isProcessingQueue = true
        Task {
            defer {
                isProcessingQueue = false
                processDownloadQueue()
            }
            let batch = Array(downloadQueue.prefix(10))
            downloadQueue.removeFirst(batch.count)
            toast.show(batch.count == 1 ? "正在通过 steamcmd 下载…" : "正在通过 steamcmd 下载 \(batch.count) 个壁纸…", style: .progress)

            do {
                let result = try await SteamCMDDownloader.shared.download(ids: batch, username: steamUsername)
                // steamcmd 的下载目录不在库里时（自定义安装路径），把它的上级目录加入库
                for folder in result.downloaded.values {
                    let root = folder.deletingLastPathComponent()
                    if !libraryRoots.contains(where: { $0.standardizedFileURL == root.standardizedFileURL }) {
                        setExtraFolders(extraFolders + [root])
                    }
                }
                let items = await Task.detached { [roots = libraryRoots] in WorkshopLibrary.scan(roots: roots) }.value
                libraryItems = items
                mergeDownloadState()
                downloading.subtract(batch)

                if result.failed.isEmpty {
                    toast.show(result.downloaded.count == 1 ? "下载完成" : "已下载 \(result.downloaded.count) 个壁纸", style: .success)
                } else {
                    let reason = result.failed.values.first ?? ""
                    toast.show("\(result.failed.count) 个壁纸下载失败：\(reason)", style: .error)
                }

                if let id = applyAfterDownload, result.downloaded[id] != nil,
                   let downloaded = libraryItems.first(where: { $0.id == id }) {
                    applyAfterDownload = nil
                    apply(downloaded)
                }
            } catch {
                downloading.subtract(batch)
                toast.show(error.localizedDescription, style: .error)
            }
        }
    }

    /// 排队中的直接移出队列；正在下载的会终止当前这一批
    func cancelDownload(_ item: WorkshopItem) {
        if let index = downloadQueue.firstIndex(of: item.id) {
            downloadQueue.remove(at: index)
            downloading.remove(item.id)
        } else {
            SteamCMDDownloader.shared.cancel(item.id)
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
                let ids = try await account.subscribedIDs()
                var details: [WorkshopItem] = []
                for start in stride(from: 0, to: ids.count, by: 100) {
                    details += try await api.details(ids: Array(ids[start..<min(start + 100, ids.count)]))
                }
                subscribedIDs = Set(ids)
                subscribedItems = details
                lastSyncAt = Date()
                mergeDownloadState()

                // Windows 上新订阅的壁纸自动下载到 Mac
                if autoDownloadSubscriptions {
                    let localIDs = Set(libraryItems.map(\.id))
                    let missing = details.filter { !localIDs.contains($0.id) && $0.type.isPlayable }.map(\.id)
                    if !missing.isEmpty { enqueueDownloads(missing) }
                }
                if force {
                    toast.show("已同步 \(ids.count) 个订阅", style: .success)
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
        // 先更新界面，失败再回滚
        if subscribed {
            subscribedIDs.insert(item.id)
            if !subscribedItems.contains(where: { $0.id == item.id }) { subscribedItems.insert(item, at: 0) }
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
                    subscribedItems.insert(item, at: 0)
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
