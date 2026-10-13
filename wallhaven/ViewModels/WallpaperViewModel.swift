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
    @Published var query = "" { didSet { saveDiscoveryPreferences() } }
    @Published var sortOrder: SortOrder = .favorites { didSet { saveDiscoveryPreferences() } }
    @Published var includeGeneral = true { didSet { saveDiscoveryPreferences() } }
    @Published var includeAnime = true { didSet { saveDiscoveryPreferences() } }
    @Published var includePeople = true { didSet { saveDiscoveryPreferences() } }
    @Published var includeSFW = true { didSet { saveDiscoveryPreferences() } }
    @Published var includeSketchy = false { didSet { saveDiscoveryPreferences() } }
    @Published var includeNSFW = false { didSet { saveDiscoveryPreferences() } }
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
    @Published private(set) var tagsByID: [String: [String]] = [:]

    private let discoveryDefaults: UserDefaults
    private var isRestoringDiscovery = false
    private static let discoveryKey = "wallper.discovery.preferences.v1"

    private let client = WallhavenClient()
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

    init(discoveryDefaults: UserDefaults = .standard) {
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
            "sfw": includeSFW, "sketchy": includeSketchy, "nsfw": includeNSFW
        ], forKey: Self.discoveryKey)
    }

    func search(reset: Bool) {
        Task {
            if reset {
                currentPage = 1
                canLoadMore = true
                wallpapers = []
                selectedWallpaper = nil
            }
            await fetch()
        }
    }

    func loadMoreIfNeeded(current item: WallhavenWallpaper) {
        guard canLoadMore, !isLoading else { return }
        let threshold = max(wallpapers.count - 8, 0)
        if let index = wallpapers.lastIndex(where: { $0.id == item.id }), index >= threshold {
            loadNextPage()
        }
    }

    func loadNextPage() {
        guard canLoadMore, !isLoading else { return }
        let nextPage = currentPage + 1
        guard nextPage <= maxPageLimit else {
            canLoadMore = false
            return
        }
        currentPage = nextPage
        Task { await fetch() }
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
                favorites.remove(wallpaper.id)
                favoriteWallpapers.removeAll(where: { $0.id == wallpaper.id })
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
        search(reset: true)
    }

    func toggleAnime() {
        includeAnime.toggle()
        if !includeGeneral && !includeAnime && !includePeople {
            includeAnime = true
            return
        }
        search(reset: true)
    }

    func togglePeople() {
        includePeople.toggle()
        if !includeGeneral && !includeAnime && !includePeople {
            includePeople = true
            return
        }
        search(reset: true)
    }

    func toggleSFW() {
        includeSFW.toggle()
        if !includeSFW && !includeSketchy && !includeNSFW {
            includeSFW = true
            return
        }
        search(reset: true)
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
        search(reset: true)
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
        search(reset: true)
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
        Task {
            do {
                ToastCenter.shared.show("正在下载…", style: .progress)
                _ = try await downloader.download(wallpaper)
                ToastCenter.shared.show("已保存到本地", style: .success)
            } catch {
                ToastCenter.shared.show("下载失败：\(error.localizedDescription)", style: .error)
            }
        }
    }

    func downloadAndApply(_ wallpaper: WallhavenWallpaper) {
        PlaylistManager.shared.userDidApplyManually()
        Task {
            do {
                ToastCenter.shared.show("正在下载并设为壁纸…", style: .progress)
                let localURL = try await downloader.download(wallpaper)
                try WallpaperManager.applyWallpaper(from: localURL)
                ToastCenter.shared.show("壁纸已应用", style: .success)
            } catch {
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
        guard tagsByID[wallpaper.id] == nil else { return }
        do {
            let tags = try await client.fetchWallpaperDetails(id: wallpaper.id, apiKey: storedAPIKey)
            tagsByID[wallpaper.id] = tags
        } catch {
            // 标签只是锦上添花，失败时静默
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

    private func fetch() async {
        isLoading = true
        errorMessage = nil
        do {
            if sortOrder == .favorites {
                // 读取本地收藏的图片数据并转换为 Array。由于 favorites 是 ID 集合，
                // 我们直接利用 ID 信息搜索对应的详细图片数据会很慢（需要一一 fetch details）。
                // 为了演示，我们将以 fallback 方式执行：如果没登入没绑定 apiKey，只能看本地 ID？
                // 实际上我们可以通过传入已存储的 likes id 集合在 UI 上展示。
                // 若不想太复杂，暂时先继续使用原有 API filter (如果 API 支持 favorites sort)，
                // 然而目前 Wallhaven v1 的 search 接口支持 `sorting=favorites`。这会调用你在网站上的 collections/likes。
                // 单向拉取已经合并到本地 `favorites` Set 了。如果想看到本地+线上的合并，
                // 我们应该只拉取并展示已经缓存在本地 favorites 的那些，但 API 没提供通过 ID 列表批量查询的 endpoint。
                // 所以我们还是按照常规 search 调用，使用 sorting=favorites 依旧会拉取官方算法给出的 favorites（可能包括别人的？或者你个人的，根据文档，如果是你的 apikey，会返回你的设定的？由于墙外文档，我们姑且照旧传 sortOrder）。
            }

            var pageToFetch = currentPage
            var skippedDuplicatePages = 0
            var appended = false

            while !appended, canLoadMore, pageToFetch <= maxPageLimit {
                let result = try await client.search(
                    query: query,
                    page: pageToFetch,
                    sorting: sortOrder,
                    categories: categoriesValue,
                    purity: purityValue,
                    apiKey: storedAPIKey
                )

                if result.isEmpty {
                    canLoadMore = false
                    break
                }

                var seenIDs = Set(wallpapers.map(\.id))
                let uniqueResult = result.filter { seenIDs.insert($0.id).inserted }
                if uniqueResult.isEmpty {
                    skippedDuplicatePages += 1
                    if skippedDuplicatePages >= 8 {
                        canLoadMore = false
                        break
                    }
                    pageToFetch += 1
                    continue
                }

                wallpapers.append(contentsOf: uniqueResult)
                currentPage = pageToFetch
                appended = true
            }

            if selectedWallpaper == nil {
                selectedWallpaper = wallpapers.randomElement()
            }
            statusMessage = "已加载 \(wallpapers.count) 张壁纸"
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
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
