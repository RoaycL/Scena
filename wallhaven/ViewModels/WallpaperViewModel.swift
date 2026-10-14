//
//  WallpaperViewModel.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import AppKit
import Combine
import SwiftUI

struct WallhavenSearchRequest: Equatable {
    let query: String
    let sorting: SortOrder
    let categories: String
    let purity: String
    let resolutions: [String]
    let apiKey: String?
}

@MainActor
final class WallpaperViewModel: ObservableObject {
    @Published var query = "" { didSet { saveDiscoveryPreferences() } }
    @Published var sortOrder: SortOrder = .favorites { didSet { saveDiscoveryPreferences() } }
    @Published var includeGeneral = true { didSet { saveDiscoveryPreferences() } }
    @Published var includeAnime = true { didSet { saveDiscoveryPreferences() } }
    @Published var includePeople = true { didSet { saveDiscoveryPreferences() } }
    @Published var includeSFW = true { didSet { saveDiscoveryPreferences() } }
    @Published var includeSketchy = false { didSet { saveDiscoveryPreferences() } }
    @Published var includeNSFW = false { didSet { saveDiscoveryPreferences() } }
    /// 分辨率筛选（精确匹配，可多选）；空集合表示不限
    @Published private(set) var resolutions: Set<String> = [] { didSet { saveDiscoveryPreferences() } }
    /// 加载失败的说明；有值时缩略图条末尾显示「重试」
    @Published private(set) var loadError: String?

    static let resolutionOptions = ["1920x1080", "2560x1440", "3440x1440", "3840x2160", "5120x2880"]
    @Published var apiKeyInput = ""
    @Published var usernameInput = ""
    @Published private(set) var isAuthenticated = false
    @Published private(set) var wallpapers: [WallhavenWallpaper] = []
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var favoriteWallpapers: [WallhavenWallpaper] = []
    @Published var selectedWallpaper: WallhavenWallpaper?
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
    private static let discoveryKey = "wallper.discovery.preferences.v1"

    private let client = WallhavenClient()
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var committedSearch: WallhavenSearchRequest?
    private var needsReplacement = false
    private let searchLoader: (@MainActor (WallhavenSearchRequest, Int) async throws -> [WallhavenWallpaper])?
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
         searchLoader: (@MainActor (WallhavenSearchRequest, Int) async throws -> [WallhavenWallpaper])? = nil) {
        self.searchLoader = searchLoader
        self.discoveryDefaults = discoveryDefaults
        isRestoringDiscovery = true
        if let saved = discoveryDefaults.dictionary(forKey: Self.discoveryKey) {
            query = saved["query"] as? String ?? ""
            sortOrder = (saved["sortOrder"] as? String).flatMap(SortOrder.init(rawValue:)) ?? .favorites
            includeGeneral = saved["general"] as? Bool ?? true
            includeAnime = saved["anime"] as? Bool ?? true
            includePeople = saved["people"] as? Bool ?? true
            includeSFW = saved["sfw"] as? Bool ?? true
            includeSketchy = saved["sketchy"] as? Bool ?? false
            includeNSFW = saved["nsfw"] as? Bool ?? false
            resolutions = Set(saved["resolutions"] as? [String] ?? [])
        }
        isRestoringDiscovery = false
        loadFavorites()
        loadFolders()
        loadAuth()
    }

    private func saveDiscoveryPreferences() {
        guard !isRestoringDiscovery else { return }
        discoveryDefaults.set([
            "query": query, "sortOrder": sortOrder.rawValue,
            "general": includeGeneral, "anime": includeAnime, "people": includePeople,
            "sfw": includeSFW, "sketchy": includeSketchy, "nsfw": includeNSFW,
            "resolutions": resolutions.sorted()
        ], forKey: Self.discoveryKey)
    }

    private var searchRequest: WallhavenSearchRequest {
        WallhavenSearchRequest(query: query, sorting: sortOrder, categories: categoriesValue,
                               purity: purityValue, resolutions: resolutions.sorted(), apiKey: storedAPIKey)
    }

    func search(reset: Bool, debounce: Bool = false) {
        if !reset { loadNextPage(); return }
        needsReplacement = true
        startSearch(request: searchRequest, page: 1, replacing: true, debounce: debounce)
    }

    private func startSearch(request: WallhavenSearchRequest, page: Int, replacing: Bool, debounce: Bool) {
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

    func loadMoreIfNeeded(current item: WallhavenWallpaper) {
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

    /// nil 表示「不限」
    func toggleResolution(_ resolution: String?) {
        if let resolution {
            resolutions.formSymmetricDifference([resolution])
        } else {
            resolutions = []
        }
        search(reset: true, debounce: true)
    }

    func toggleFavorite(_ wallpaper: WallhavenWallpaper, insertOnly: Bool = false) {
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

    private func restoreFavorite(_ wallpaper: WallhavenWallpaper, at index: Int?) {
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

    func addToFolder(_ wallpaper: WallhavenWallpaper, folderID: UUID) {
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

    func wallpapersInFolder(_ folderID: UUID) -> [WallhavenWallpaper] {
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
        includeSketchy = false
        includeNSFW = false
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
                    let wallpapers = response.data
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
            if sortOrder == .favorites {
                search(reset: true)
            }
        } catch {
            isSyncing = false
            syncProgress = ""
            errorMessage = "同步失败: \(error.localizedDescription)"
        }
    }

    func toggleGeneral() {
        includeGeneral.toggle()
        if !includeGeneral && !includeAnime && !includePeople {
            includeGeneral = true
            return
        }
        search(reset: true, debounce: true)
    }

    func toggleAnime() {
        includeAnime.toggle()
        if !includeGeneral && !includeAnime && !includePeople {
            includeAnime = true
            return
        }
        search(reset: true, debounce: true)
    }

    func togglePeople() {
        includePeople.toggle()
        if !includeGeneral && !includeAnime && !includePeople {
            includePeople = true
            return
        }
        search(reset: true, debounce: true)
    }

    func toggleSFW() {
        includeSFW.toggle()
        if !includeSFW && !includeSketchy && !includeNSFW {
            includeSFW = true
            return
        }
        search(reset: true, debounce: true)
    }

    func toggleSketchy() {
        guard isAuthenticated else {
            errorMessage = "需要登录才能开启 Sketchy。"
            return
        }
        includeSketchy.toggle()
        if !includeSFW && !includeSketchy && !includeNSFW {
            includeSketchy = true
            return
        }
        search(reset: true, debounce: true)
    }

    func toggleNSFW() {
        guard isAuthenticated else {
            errorMessage = "需要登录才能开启 NSFW。"
            return
        }
        includeNSFW.toggle()
        if !includeSFW && !includeSketchy && !includeNSFW {
            includeNSFW = true
            return
        }
        search(reset: true, debounce: true)
    }

    func openAPIKeyPage() {
        guard let url = URL(string: "https://wallhaven.cc/settings/account") else { return }
        NSWorkspace.shared.open(url)
    }

    func downloadAndApplySelected() {
        guard let selectedWallpaper else { return }
        downloadAndApply(selectedWallpaper)
    }

    func downloadImage(_ wallpaper: WallhavenWallpaper) {
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

    func downloadAndApply(_ wallpaper: WallhavenWallpaper) {
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
        Task {
            do {
                let results = try await client.search(
                    query: query,
                    page: 1,
                    sorting: .random,
                    categories: categoriesValue,
                    purity: purityValue,
                    apiKey: storedAPIKey
                )
                if let wallpaper = results.randomElement() {
                    downloadAndApply(wallpaper)
                }
            } catch {
                ToastCenter.shared.show("获取随机壁纸失败：\(error.localizedDescription)", style: .error)
            }
        }
    }

    /// 按需加载壁纸标签（详情接口），结果缓存
    func loadTagsIfNeeded(for wallpaper: WallhavenWallpaper) async {
        guard tagsByID[wallpaper.id] == nil, tagRequests.insert(wallpaper.id).inserted else { return }
        defer { tagRequests.remove(wallpaper.id) }
        do {
            let tags = try await client.fetchWallpaperDetails(id: wallpaper.id, apiKey: storedAPIKey)
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
        NSWorkspace.shared.open(selectedWallpaper.url)
    }

    private func fetch(request: WallhavenSearchRequest, page: Int, replacing: Bool, generation: UUID) async throws {
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

    private func searchWithRetry(request: WallhavenSearchRequest, page: Int) async throws -> [WallhavenWallpaper] {
        let delays = [2, 5]
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                if let searchLoader { return try await searchLoader(request, page) }
                return try await client.search(query: request.query, page: page, sorting: request.sorting,
                                               categories: request.categories, purity: request.purity,
                                               resolutions: request.resolutions, apiKey: request.apiKey)
            } catch {
                try Task.checkCancellation()
                let retryable = error is WallhavenRateLimited || (error as? URLError).map {
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
           let decoded = try? JSONDecoder().decode([WallhavenWallpaper].self, from: data) {
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

    private var categoriesValue: String {
        let general = includeGeneral ? "1" : "0"
        let anime = includeAnime ? "1" : "0"
        let people = includePeople ? "1" : "0"
        return "\(general)\(anime)\(people)"
    }

    private var purityValue: String {
        let sfw = includeSFW ? "1" : "0"
        let sketchy = includeSketchy ? "1" : "0"
        let nsfw = includeNSFW ? "1" : "0"
        return "\(sfw)\(sketchy)\(nsfw)"
    }
}
