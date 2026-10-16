//
//  WallpaperViewModel.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class WallpaperViewModel: ObservableObject {
    /// 当前图源：搜索、筛选项、排序都由它决定
    @Published private(set) var source: any WallpaperSource
    @Published var query = "" { didSet { saveDiscoveryPreferences() } }
    @Published var sortID = "" { didSet { saveDiscoveryPreferences() } }
    /// 筛选 ID → 选中的选项 ID（选项由图源的 descriptor 定义）
    @Published private(set) var filterSelections: [String: Set<String>] = [:] { didSet { saveDiscoveryPreferences() } }
    /// 加载失败的说明；有值时缩略图条末尾显示「重试」
    @Published private(set) var loadError: String?

    @Published var apiKeyInput = ""
    @Published var usernameInput = ""
    @Published private(set) var isAuthenticated = false
    @Published private(set) var wallpapers: [RemoteWallpaper] = []
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var favoriteWallpapers: [RemoteWallpaper] = []
    @Published var selectedWallpaper: RemoteWallpaper?
    @Published private(set) var isLoading = false
    @Published var isSyncing = false
    @Published var syncProgress = ""
    @Published var errorMessage: String?
    @Published private(set) var statusMessage = "就绪"
    @Published var favoriteFolders: [FavoriteFolder] = []
    @Published var selectedFolderID: UUID? = nil  // nil = 显示全部收藏
    /// 壁纸标签（详情接口）：持久化到缓存目录，再次查看或切到收藏时无需重新请求
    /// 正在下载 / 本次刚下载完成的壁纸：下载按钮据此在「下载中 → 已下载」之间过渡
    /// （资料库扫描到新文件前，用 downloadedIDs 先显示为已下载，避免按钮闪回箭头）
    @Published private(set) var downloadingIDs: Set<String> = []
    @Published private(set) var downloadedIDs: Set<String> = []
    @Published private(set) var tagsByID: [String: [String]] = WallpaperViewModel.loadTagCache()
    private var tagCacheSave: Task<Void, Never>?
    private var tagRequests: Set<String> = []

    private let discoveryDefaults: UserDefaults
    private var isRestoringDiscovery = false
    private static let legacyDiscoveryKey = "wallper.discovery.preferences.v1"
    private static let selectedSourceKey = "wallper.discovery.source"
    private static func discoveryKey(_ sourceID: String) -> String { "wallper.discovery.\(sourceID).v2" }

    /// Wallhaven 账号（登录校验、云端收藏夹同步）
    private let client = WallhavenClient()
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var committedSearch: WallpaperQuery?
    private var needsReplacement = false
    /// 重新搜索中（旧结果保留、等待替换），界面据此把旧内容变暗
    var isRefreshing: Bool { isLoading && needsReplacement }
    private let searchLoader: (@MainActor (WallpaperQuery, Int) async throws -> [RemoteWallpaper])?
    private let downloader = DownloadService()
    private let favoritesKey = "wallper.favorites.ids"
    private let favoriteObjectsKey = "wallper.favorites.objects"
    private let favoriteFoldersKey = "wallper.favorites.folders"
    private let apiKeyStorageKey = "wallper.wallhaven.apikey"
    private let usernameStorageKey = "wallper.wallhaven.username"
    private var currentPage = 1
    private var canLoadMore = true
    private let maxPageLimit = 200
    private var storedAPIKey: String?
    private var storedUsername: String?

    init(discoveryDefaults: UserDefaults = .standard,
         sources: [any WallpaperSource] = WallpaperSources.all,
         searchLoader: (@MainActor (WallpaperQuery, Int) async throws -> [RemoteWallpaper])? = nil) {
        self.searchLoader = searchLoader
        self.discoveryDefaults = discoveryDefaults
        let savedID = discoveryDefaults.string(forKey: Self.selectedSourceKey)
        source = sources.first { $0.descriptor.id == savedID } ?? sources[0]
        loadAuth()
        restoreDiscoveryPreferences()
        loadFavorites()
        loadFolders()
    }

    var descriptor: WallpaperSourceDescriptor { source.descriptor }

    /// 切换图源：恢复该图源上次的搜索条件并重新搜索
    func selectSource(_ newSource: any WallpaperSource) {
        guard newSource.descriptor.id != descriptor.id else { return }
        source = newSource
        discoveryDefaults.set(newSource.descriptor.id, forKey: Self.selectedSourceKey)
        restoreDiscoveryPreferences()
        wallpapers = []
        selectedWallpaper = nil
        search(reset: true)
    }

    private func restoreDiscoveryPreferences() {
        isRestoringDiscovery = true
        defer { isRestoringDiscovery = false }
        var saved = discoveryDefaults.dictionary(forKey: Self.discoveryKey(descriptor.id))
        if saved == nil, descriptor.id == WallhavenSource.id {
            saved = discoveryDefaults.dictionary(forKey: Self.legacyDiscoveryKey).map(Self.migrateLegacyDiscovery)
        }
        query = saved?["query"] as? String ?? ""
        let sort = saved?["sort"] as? String ?? ""
        sortID = descriptor.sorts.contains { $0.id == sort } ? sort : descriptor.defaultSort
        let filters = saved?["filters"] as? [String: [String]] ?? [:]
        filterSelections = Dictionary(uniqueKeysWithValues: descriptor.filters.map { filter in
            let valid = Set(filter.options.filter { isAvailable($0) }.map(\.id))
            var selection = filters[filter.id].map(Set.init) ?? filter.defaultSelection
            selection.formIntersection(valid)
            if selection.isEmpty, filter.mode == .atLeastOne { selection = filter.defaultSelection.intersection(valid) }
            return (filter.id, selection)
        })
    }

    /// 1.0.26 及更早版本只有 Wallhaven，筛选条件按开关分别存储
    private static func migrateLegacyDiscovery(_ legacy: [String: Any]) -> [String: Any] {
        func ids(_ pairs: [(String, String, Bool)]) -> [String] {
            pairs.filter { legacy[$0.0] as? Bool ?? $0.2 }.map(\.1)
        }
        return [
            "query": legacy["query"] as? String ?? "",
            "sort": legacy["sortOrder"] as? String ?? "",
            "filters": [
                "categories": ids([("general", "general", true), ("anime", "anime", true), ("people", "people", true)]),
                "purity": ids([("sfw", "sfw", true), ("sketchy", "sketchy", false), ("nsfw", "nsfw", false)]),
                "resolutions": legacy["resolutions"] as? [String] ?? [],
            ],
        ]
    }

    private func saveDiscoveryPreferences() {
        guard !isRestoringDiscovery else { return }
        discoveryDefaults.set([
            "query": query, "sort": sortID,
            "filters": filterSelections.mapValues { $0.sorted() },
        ], forKey: Self.discoveryKey(descriptor.id))
    }

    private var searchRequest: WallpaperQuery {
        WallpaperQuery(text: query, sort: sortID, filters: filterSelections, credential: credential(for: descriptor.id))
    }

    /// 图源账号凭据；目前只有 Wallhaven 有账号
    private func credential(for sourceID: String) -> String? {
        sourceID == WallhavenSource.id ? storedAPIKey : nil
    }

    // MARK: - 筛选

    func isSelected(_ option: SourceOption, in filter: SourceFilter) -> Bool {
        filterSelections[filter.id]?.contains(option.id) ?? false
    }

    /// 需要登录的选项在未登录时不可选
    func isAvailable(_ option: SourceOption) -> Bool {
        !option.requiresAccount || isAuthenticated
    }

    /// 切换筛选项；option 为 nil 表示「不限」（清空可多选的筛选）
    func toggle(_ option: SourceOption?, in filter: SourceFilter) {
        var selection = filterSelections[filter.id] ?? []
        if let option {
            guard isAvailable(option) else {
                errorMessage = "需要登录才能开启 \(option.title)。"
                return
            }
            selection.formSymmetricDifference([option.id])
            // 至少保留一项：取消最后一项时不生效
            if selection.isEmpty, filter.mode == .atLeastOne { return }
        } else {
            selection = []
        }
        filterSelections[filter.id] = selection
        search(reset: true, debounce: true)
    }

    func search(reset: Bool, debounce: Bool = false) {
        if !reset { loadNextPage(); return }
        needsReplacement = true
        startSearch(request: searchRequest, page: 1, replacing: true, debounce: debounce)
    }

    private func startSearch(request: WallpaperQuery, page: Int, replacing: Bool, debounce: Bool) {
        searchTask?.cancel()
        let generation = UUID()
        searchGeneration = generation
        // 从防抖开始即标记加载，保留旧内容，但阻止旧列表继续翻页。
        isLoading = true
        errorMessage = nil
        loadError = nil
        searchTask = Task {
            do {
                if debounce { try await Task.sleep(for: .milliseconds(300)) }
                try Task.checkCancellation()
                try await fetch(request: request, page: page, replacing: replacing, generation: generation)
            } catch {
                guard generation == searchGeneration, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                loadError = error.localizedDescription
            }
            guard generation == searchGeneration else { return }
            isLoading = false
            searchTask = nil
        }
    }

    func loadMoreIfNeeded(current item: RemoteWallpaper) {
        guard canLoadMore, !isLoading, !needsReplacement else { return }
        let threshold = max(wallpapers.count - 8, 0)
        if let index = wallpapers.lastIndex(where: { $0.id == item.id }), index >= threshold {
            loadNextPage()
        }
    }

    func loadNextPage() {
        guard canLoadMore, !isLoading, !needsReplacement else { return }
        let nextPage = currentPage + 1
        guard nextPage <= maxPageLimit else { canLoadMore = false; return }
        startSearch(request: committedSearch ?? searchRequest, page: nextPage, replacing: false, debounce: false)
    }

    func retryLoading() {
        if needsReplacement || wallpapers.isEmpty { search(reset: true) }
        else { loadNextPage() }
    }

    func toggleFavorite(_ wallpaper: RemoteWallpaper, insertOnly: Bool = false) {
        if insertOnly {
            if !favorites.contains(wallpaper.id) {
                favorites.insert(wallpaper.id)
                favoriteWallpapers.append(wallpaper)
            } else if !favoriteWallpapers.contains(where: { $0.id == wallpaper.id }) {
                // ID 已在收藏集合中但对象丢失（可能因 UserDefaults 数据过大加载失败），补回对象
                favoriteWallpapers.append(wallpaper)
            }
        } else {
            if favorites.contains(wallpaper.id) {
                let index = favoriteWallpapers.firstIndex { $0.id == wallpaper.id }
                favorites.remove(wallpaper.id)
                favoriteWallpapers.removeAll(where: { $0.id == wallpaper.id })
                // 取消收藏可撤销：放回原来的位置
                ToastCenter.shared.show("已取消收藏", style: .info, actionTitle: "撤销") { [weak self] in
                    self?.restoreFavorite(wallpaper, at: index)
                }
            } else {
                favorites.insert(wallpaper.id)
                favoriteWallpapers.append(wallpaper)
            }
        }
        UserDefaults.standard.set(Array(favorites), forKey: favoritesKey)
        if let data = try? JSONEncoder().encode(favoriteWallpapers) {
            UserDefaults.standard.set(data, forKey: favoriteObjectsKey)
        }
    }

    private func restoreFavorite(_ wallpaper: RemoteWallpaper, at index: Int?) {
        guard !favorites.contains(wallpaper.id) else { return }
        favorites.insert(wallpaper.id)
        favoriteWallpapers.insert(wallpaper, at: min(index ?? favoriteWallpapers.count, favoriteWallpapers.count))
        UserDefaults.standard.set(Array(favorites), forKey: favoritesKey)
        if let data = try? JSONEncoder().encode(favoriteWallpapers) {
            UserDefaults.standard.set(data, forKey: favoriteObjectsKey)
        }
    }

    func isFavorite(_ id: String) -> Bool {
        favorites.contains(id)
    }

    // MARK: - 收藏夹管理

    func createFolder(name: String) -> FavoriteFolder {
        let folder = FavoriteFolder(name: name)
        favoriteFolders.append(folder)
        saveFolders()
        return folder
    }

    func deleteFolder(_ folder: FavoriteFolder) {
        favoriteFolders.removeAll { $0.id == folder.id }
        if selectedFolderID == folder.id {
            selectedFolderID = nil
        }
        saveFolders()
    }

    func renameFolder(_ folder: FavoriteFolder, to newName: String) {
        guard let index = favoriteFolders.firstIndex(where: { $0.id == folder.id }) else { return }
        favoriteFolders[index].name = newName
        saveFolders()
    }

    func addToFolder(_ wallpaper: RemoteWallpaper, folderID: UUID) {
        // 先确保壁纸已加入全局收藏
        if !favorites.contains(wallpaper.id) {
            toggleFavorite(wallpaper, insertOnly: true)
        }
        guard let index = favoriteFolders.firstIndex(where: { $0.id == folderID }) else { return }
        if !favoriteFolders[index].wallpaperIDs.contains(wallpaper.id) {
            favoriteFolders[index].wallpaperIDs.append(wallpaper.id)
            saveFolders()
        }
    }

    func removeFromFolder(_ wallpaperID: String, folderID: UUID) {
        guard let index = favoriteFolders.firstIndex(where: { $0.id == folderID }) else { return }
        favoriteFolders[index].wallpaperIDs.removeAll { $0 == wallpaperID }
        saveFolders()
    }

    func foldersContaining(_ wallpaperID: String) -> [FavoriteFolder] {
        favoriteFolders.filter { $0.wallpaperIDs.contains(wallpaperID) }
    }

    func wallpapersInFolder(_ folderID: UUID) -> [RemoteWallpaper] {
        guard let folder = favoriteFolders.first(where: { $0.id == folderID }) else { return [] }
        return folder.wallpaperIDs.compactMap { id in
            favoriteWallpapers.first(where: { $0.id == id })
        }
    }

    private func saveFolders() {
        if let data = try? JSONEncoder().encode(favoriteFolders) {
            UserDefaults.standard.set(data, forKey: favoriteFoldersKey)
        }
    }

    private func loadFolders() {
        if let data = UserDefaults.standard.data(forKey: favoriteFoldersKey),
           let decoded = try? JSONDecoder().decode([FavoriteFolder].self, from: data) {
            favoriteFolders = decoded
        }
    }

    func login() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        // 过滤掉因为 macOS 自动补全加入在后面的句号
        let name = usernameInput.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        
        guard !key.isEmpty else {
            errorMessage = "请输入您的 Wallhaven API 密钥。"
            return
        }
        Task {
            do {
                try await client.validateAPIKey(key)
                storedAPIKey = key
                storedUsername = name
                UserDefaults.standard.set(key, forKey: apiKeyStorageKey)
                if !name.isEmpty {
                    UserDefaults.standard.set(name, forKey: usernameStorageKey)
                }
                isAuthenticated = true
                statusMessage = "已登录 Wallhaven"
                search(reset: true)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func logout() {
        storedAPIKey = nil
        storedUsername = nil
        UserDefaults.standard.removeObject(forKey: apiKeyStorageKey)
        UserDefaults.standard.removeObject(forKey: usernameStorageKey)
        apiKeyInput = ""
        usernameInput = ""
        isAuthenticated = false
        // 退出后去掉需要登录的筛选项
        for filter in descriptor.filters {
            let locked = Set(filter.options.filter(\.requiresAccount).map(\.id))
            var selection = (filterSelections[filter.id] ?? []).subtracting(locked)
            if selection.isEmpty, filter.mode == .atLeastOne { selection = filter.defaultSelection.subtracting(locked) }
            filterSelections[filter.id] = selection
        }
        statusMessage = "已登出"
        search(reset: true)
    }

    @MainActor
    func syncCollections() async {
        let key = storedAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let username = storedUsername?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? ""
        guard !key.isEmpty, !username.isEmpty else {
            errorMessage = "同步收藏需要在设置中同时配置 API 密钥和有效的 Wallhaven 用户名。"
            return
        }

        isSyncing = true
        syncProgress = "正在获取收藏夹列表..."
        errorMessage = nil

        do {
            let collections = try await client.getCollections(apiKey: key)
            if collections.isEmpty {
                syncProgress = ""
                isSyncing = false
                statusMessage = "没有找到任何线上收藏夹"
                return
            }

            var fetchedCount = 0

            for collection in collections {
                syncProgress = "正在同步收藏夹 [\(collection.label)]..."
                
                // 按云端收藏夹名称匹配本地收藏夹，没有则新建
                let folderID: UUID
                if let existingFolder = favoriteFolders.first(where: { $0.name == collection.label }) {
                    folderID = existingFolder.id
                } else {
                    let newFolder = createFolder(name: collection.label)
                    folderID = newFolder.id
                }
                
                var page = 1
                while true {
                    try await Task.sleep(nanoseconds: 1_200_000_000) // 防止触发 API 速率限制 (45/min)
                    let response = try await client.getCollectionWallpapers(username: username, collectionId: collection.id, page: page, apiKey: key)
                    let wallpapers = response.data.map(\.remote)
                    if wallpapers.isEmpty { break }

                    for wp in wallpapers {
                        toggleFavorite(wp, insertOnly: true)
                        addToFolder(wp, folderID: folderID)
                    }
                    fetchedCount += wallpapers.count
                    
                    if page >= response.meta.last_page {
                        break
                    }
                    page += 1
                }
            }

            syncProgress = ""
            isSyncing = false
            statusMessage = "同步完成，共拉取 \(fetchedCount) 张壁纸到 \(collections.count) 个收藏夹。"
            
            // 刷新
            if descriptor.id == WallhavenSource.id, sortID == "favorites" {
                search(reset: true)
            }
        } catch {
            isSyncing = false
            syncProgress = ""
            errorMessage = "同步失败: \(error.localizedDescription)"
        }
    }

    func openAPIKeyPage() {
        guard let url = URL(string: "https://wallhaven.cc/settings/account") else { return }
        NSWorkspace.shared.open(url)
    }

    func downloadAndApplySelected() {
        guard let selectedWallpaper else { return }
        downloadAndApply(selectedWallpaper)
    }

    func downloadImage(_ wallpaper: RemoteWallpaper) {
        guard downloadingIDs.insert(wallpaper.id).inserted else { return }
        Task {
            defer { downloadingIDs.remove(wallpaper.id) }
            do {
                // 进度和完成都显示在下载按钮上（转圈 → 绿色对勾），不再弹提示条
                _ = try await downloader.download(wallpaper)
                downloadedIDs.insert(wallpaper.id)
                NotificationCenter.default.post(name: .localMediaDidChange, object: nil)
            } catch {
                ToastCenter.shared.show("下载失败：\(error.localizedDescription)", style: .error)
            }
        }
    }

    func downloadAndApply(_ wallpaper: RemoteWallpaper) {
        PlaylistManager.shared.userDidApplyManually()
        downloadingIDs.insert(wallpaper.id)
        // 进度和结果显示在「设为壁纸」按钮上：设置中 → 已设为壁纸
        let feedbackID = GalleryItem(origin: .remote(wallpaper)).id
        ApplyFeedback.shared.begin(feedbackID)
        Task {
            defer { downloadingIDs.remove(wallpaper.id) }
            do {
                let localURL = try await downloader.download(wallpaper)
                downloadedIDs.insert(wallpaper.id)
                try WallpaperManager.applyWallpaper(from: localURL)
                ApplyFeedback.shared.finish(feedbackID, success: true)
                NotificationCenter.default.post(name: .localMediaDidChange, object: nil)
            } catch {
                ApplyFeedback.shared.finish(feedbackID, success: false)
                ToastCenter.shared.show("设置失败：\(error.localizedDescription)", style: .error)
            }
        }
    }

    /// 状态栏「随机换一张」：优先从当前列表里挑，列表为空时按当前筛选随机取一页
    func applyRandomWallpaper() {
        if let wallpaper = wallpapers.randomElement() {
            downloadAndApply(wallpaper)
            return
        }
        var request = searchRequest
        request.sort = descriptor.randomSort ?? request.sort
        let source = source
        Task {
            do {
                let results = try await source.search(request, page: 1)
                if let wallpaper = results.randomElement() {
                    downloadAndApply(wallpaper)
                }
            } catch {
                ToastCenter.shared.show("获取随机壁纸失败：\(error.localizedDescription)", style: .error)
            }
        }
    }

    /// 按需加载壁纸标签（详情接口），结果缓存
    func loadTagsIfNeeded(for wallpaper: RemoteWallpaper) async {
        guard tagsByID[wallpaper.id] == nil, tagRequests.insert(wallpaper.id).inserted else { return }
        defer { tagRequests.remove(wallpaper.id) }
        do {
            guard let source = WallpaperSources.source(id: wallpaper.sourceID) else { return }
            let tags = try await source.tags(for: wallpaper, credential: credential(for: wallpaper.sourceID))
            tagsByID[wallpaper.id] = tags
            scheduleTagCacheSave()
        } catch {
            // 标签只是锦上添花，失败时静默
        }
    }

    private static let tagCacheLimit = 5000

    private static var tagCacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.roayc.wallhaven", isDirectory: true)
            .appendingPathComponent("wallhaven-tags.json")
    }

    private static func loadTagCache() -> [String: [String]] {
        guard let url = tagCacheURL, let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return cache
    }

    /// 合并短时间内的多次写入；超过上限时丢掉一部分旧条目（字典无序，只为控制体积）
    private func scheduleTagCacheSave() {
        tagCacheSave?.cancel()
        tagCacheSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, let url = Self.tagCacheURL else { return }
            var cache = tagsByID
            if cache.count > Self.tagCacheLimit {
                for key in cache.keys.prefix(cache.count - Self.tagCacheLimit) { cache.removeValue(forKey: key) }
            }
            guard let data = try? JSONEncoder().encode(cache) else { return }
            Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// 点击标签：以该标签为关键词重新搜索
    func searchTag(_ tag: String) {
        query = tag
        search(reset: true)
    }

    func openSelectedInBrowser() {
        guard let selectedWallpaper else { return }
        NSWorkspace.shared.open(selectedWallpaper.pageURL)
    }

    private func fetch(request: WallpaperQuery, page: Int, replacing: Bool, generation: UUID) async throws {
        var staged = replacing ? [] : wallpapers
        var pageToFetch = page
        var hasMore = true
        var skippedDuplicatePages = 0
        while hasMore, pageToFetch <= maxPageLimit {
            let result = try await searchWithRetry(request: request, page: pageToFetch)
            // 网络层即使不响应取消，过期结果也不能修改条目、页码或加载状态。
            guard generation == searchGeneration, !Task.isCancelled else { throw CancellationError() }
            if result.isEmpty { hasMore = false; break }
            var seenIDs = Set(staged.map(\.id))
            let unique = result.filter { seenIDs.insert($0.id).inserted }
            if unique.isEmpty {
                skippedDuplicatePages += 1
                if skippedDuplicatePages >= 8 { hasMore = false; break }
                pageToFetch += 1
                continue
            }
            staged.append(contentsOf: unique)
            break
        }
        guard generation == searchGeneration, !Task.isCancelled else { throw CancellationError() }
        let previousSelection = selectedWallpaper?.id
        wallpapers = staged
        currentPage = min(pageToFetch, maxPageLimit)
        canLoadMore = hasMore && pageToFetch < maxPageLimit
        if replacing {
            committedSearch = request
            needsReplacement = false
            selectedWallpaper = staged.first { $0.id == previousSelection } ?? staged.first
        } else if selectedWallpaper == nil { selectedWallpaper = staged.first }
        statusMessage = "已加载 \(staged.count) 张壁纸"
    }

    private func searchWithRetry(request: WallpaperQuery, page: Int) async throws -> [RemoteWallpaper] {
        let delays = [2, 5]
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                if let searchLoader { return try await searchLoader(request, page) }
                return try await source.search(request, page: page)
            } catch {
                try Task.checkCancellation()
                let retryable = error is TransientSourceError || (error as? URLError).map {
                    [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains($0.code)
                } == true
                guard retryable, attempt < delays.count else { throw error }
                try await Task.sleep(for: .seconds(delays[attempt]))
                attempt += 1
            }
        }
    }

    private func loadFavorites() {
        if let data = UserDefaults.standard.data(forKey: favoriteObjectsKey),
           let decoded = try? JSONDecoder().decode([RemoteWallpaper].self, from: data) {
            favoriteWallpapers = decoded
            favorites = Set(decoded.map { $0.id })
            
            // Append missing IDs from older versions just in case
            let storedIds = UserDefaults.standard.array(forKey: favoritesKey) as? [String] ?? []
            for storedId in storedIds where !favorites.contains(storedId) {
                favorites.insert(storedId)
            }
        } else {
            let stored = UserDefaults.standard.array(forKey: favoritesKey) as? [String] ?? []
            favorites = Set(stored)
            favoriteWallpapers = []
        }
    }

    private func loadAuth() {
        let stored = UserDefaults.standard.string(forKey: apiKeyStorageKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty {
            storedAPIKey = stored
            apiKeyInput = stored
            isAuthenticated = true
        }

        let userStored = UserDefaults.standard.string(forKey: usernameStorageKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let userStored, !userStored.isEmpty {
            storedUsername = userStored
            usernameInput = userStored
        }
    }
}
