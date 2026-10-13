//
//  ContentView.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import AppKit
import Combine
import SwiftUI
import Kingfisher

struct FavoriteFolder: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var wallpaperIDs: [String]
    
    init(id: UUID = UUID(), name: String, wallpaperIDs: [String] = []) {
        self.id = id
        self.name = name
        self.wallpaperIDs = wallpaperIDs
    }
}

struct WallhavenCollection: Decodable, Sendable {
    let id: Int
    let label: String
    let views: Int
    let count: Int
}

struct WallhavenCollectionsResponse: Decodable, Sendable {
    let data: [WallhavenCollection]
}

struct WallhavenCollectionWallpapersResponse: Decodable, Sendable {
    let data: [WallhavenWallpaper]
    let meta: WallhavenMeta
}

struct WallhavenMeta: Decodable, Sendable {
    let current_page: Int
    let last_page: Int
}


struct WallhavenSearchResponse: Decodable, Sendable {
    let data: [WallhavenWallpaper]
}

struct WallhavenSettingsResponse: Decodable, Sendable {
    let data: WallhavenSettingsData
}

struct WallhavenSettingsData: Decodable, Sendable {
    let purity: [String]
}

struct WallhavenWallpaper: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let path: URL
    let thumbURL: URL?
    let resolution: String
    let category: String
    let favorites: Int
    let ratio: String
    let purity: String

    enum CodingKeys: String, CodingKey {
        case id
        case url
        case path
        case thumbs
        case resolution
        case category
        case favorites
        case ratio
        case purity
    }

    enum ThumbsCodingKeys: String, CodingKey {
        case large
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        url = try container.decode(URL.self, forKey: .url)
        path = try container.decode(URL.self, forKey: .path)
        resolution = try container.decode(String.self, forKey: .resolution)
        category = try container.decode(String.self, forKey: .category)
        favorites = try container.decode(Int.self, forKey: .favorites)
        ratio = try container.decode(String.self, forKey: .ratio)
        purity = try container.decode(String.self, forKey: .purity)

        if let thumbsContainer = try? container.nestedContainer(keyedBy: ThumbsCodingKeys.self, forKey: .thumbs) {
            thumbURL = try thumbsContainer.decodeIfPresent(URL.self, forKey: .large)
        } else {
            thumbURL = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(path, forKey: .path)
        try container.encode(resolution, forKey: .resolution)
        try container.encode(category, forKey: .category)
        try container.encode(favorites, forKey: .favorites)
        try container.encode(ratio, forKey: .ratio)
        try container.encode(purity, forKey: .purity)

        var thumbsContainer = container.nestedContainer(keyedBy: ThumbsCodingKeys.self, forKey: .thumbs)
        try thumbsContainer.encodeIfPresent(thumbURL, forKey: .large)
    }
}

enum SortOrder: String, CaseIterable, Identifiable, Sendable {
    case relevance
    case random
    case dateAdded = "date_added"
    case views
    case favorites
    case toplist

    var id: String { rawValue }

    var label: String {
        switch self {
        case .relevance: return "相关性"
        case .random: return "随机"
        case .dateAdded: return "最新"
        case .views: return "浏览量"
        case .favorites: return "收藏数"
        case .toplist: return "热门"
        }
    }
}

enum WallperError: LocalizedError, Sendable {
    case network(String)
    case io(String)
    case wallpaper(String)

    var errorDescription: String? {
        switch self {
        case .network(let message), .io(let message), .wallpaper(let message):
            return message
        }
    }
}

struct WallhavenClient: Sendable {
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    func validateAPIKey(_ apiKey: String) async throws {
        var components = URLComponents(string: "https://wallhaven.cc/api/v1/settings")!
        components.queryItems = [.init(name: "apikey", value: apiKey)]
        let (data, response) = try await session.data(from: components.url!)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WallperError.network("无效的响应。")
        }
        if httpResponse.statusCode == 401 {
            throw WallperError.network("无效的 Wallhaven API 密钥。")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw WallperError.network("无法验证 API 密钥。")
        }
        _ = try JSONDecoder().decode(WallhavenSettingsResponse.self, from: data)
    }

    func getCollections(apiKey: String) async throws -> [WallhavenCollection] {
        var components = URLComponents(string: "https://wallhaven.cc/api/v1/collections")!
        components.queryItems = [.init(name: "apikey", value: apiKey)]
        let (data, response) = try await session.data(from: components.url!)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw WallperError.network("获取合集列表失败 (状态码: \(statusCode), \(body))")
        }
        return try JSONDecoder().decode(WallhavenCollectionsResponse.self, from: data).data
    }

    func getCollectionWallpapers(username: String, collectionId: Int, page: Int, apiKey: String) async throws -> WallhavenCollectionWallpapersResponse {
        var components = URLComponents(string: "https://wallhaven.cc/api/v1/collections/\(username)/\(collectionId)")!
        components.queryItems = [
            .init(name: "page", value: String(page)),
            .init(name: "apikey", value: apiKey)
        ]
        
        let (data, response) = try await session.data(from: components.url!)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw WallperError.network("获取合集图片失败 (状态码: \(statusCode), \(body))")
        }
        return try JSONDecoder().decode(WallhavenCollectionWallpapersResponse.self, from: data)
    }

    func search(query: String, page: Int, sorting: SortOrder, categories: String, purity: String, apiKey: String?) async throws -> [WallhavenWallpaper] {
        var components = URLComponents(string: "https://wallhaven.cc/api/v1/search")!
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var items: [URLQueryItem] = [
            .init(name: "page", value: String(page)),
            .init(name: "sorting", value: sorting.rawValue),
            .init(name: "purity", value: purity),
            .init(name: "categories", value: categories)
        ]
        if !trimmed.isEmpty {
            items.append(.init(name: "q", value: trimmed))
        }
        if let apiKey, !apiKey.isEmpty {
            items.append(.init(name: "apikey", value: apiKey))
        }
        components.queryItems = items

        let (data, response) = try await session.data(from: components.url!)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WallperError.network("无效的响应。")
        }
        if httpResponse.statusCode == 401 {
            throw WallperError.network("未授权。请检查您的 Wallhaven 登录状态。")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw WallperError.network("加载壁纸失败。")
        }
        return try JSONDecoder().decode(WallhavenSearchResponse.self, from: data).data
    }

    func fetchWallpaperDetails(id: String, apiKey: String?) async throws -> [String] {
        var components = URLComponents(string: "https://wallhaven.cc/api/v1/w/\(id)")!
        if let apiKey, !apiKey.isEmpty {
            components.queryItems = [.init(name: "apikey", value: apiKey)]
        }
        let (data, response) = try await session.data(from: components.url!)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw WallperError.network("获取详情失败。")
        }
        
        struct DetailResponse: Decodable {
            let data: DetailData
            struct DetailData: Decodable {
                let tags: [Tag]
                struct Tag: Decodable {
                    let name: String
                }
            }
        }
        
        let decoder = JSONDecoder()
        let result = try decoder.decode(DetailResponse.self, from: data)
        return result.data.tags.map { $0.name }
    }
}

struct DownloadService {
    @AppStorage("downloadPath") private var downloadPath: String = {
        return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first?.appendingPathComponent("Wallhaven").path ?? ""
    }()

    private let session = URLSession(configuration: .default)
    private let fm = FileManager.default

    func download(_ wallpaper: WallhavenWallpaper) async throws -> URL {
        let destinationFolder = URL(fileURLWithPath: downloadPath, isDirectory: true)
        if !fm.fileExists(atPath: destinationFolder.path) {
            try fm.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        }

        let ext = wallpaper.path.pathExtension.isEmpty ? "jpg" : wallpaper.path.pathExtension
        let destination = destinationFolder.appendingPathComponent("\(wallpaper.id).\(ext)")
        if fm.fileExists(atPath: destination.path) {
            return destination
        }

        let (tempURL, response) = try await session.download(from: wallpaper.path)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw WallperError.network("下载失败。")
        }
        
        // 使用 Data 写入可以避免跨卷/跨沙盒 `moveItem` 的权限问题
        let data = try Data(contentsOf: tempURL)
        try data.write(to: destination, options: .atomic)
        try? fm.removeItem(at: tempURL)
        
        return destination
    }
}

struct WallpaperManager {
    static func applyWallpaper(from fileURL: URL) throws {
        guard let screen = NSScreen.main else {
            throw WallperError.wallpaper("未找到活动屏幕。")
        }
        try NSWorkspace.shared.setDesktopImageURL(fileURL, for: screen, options: [:])
    }
}

@MainActor
final class WallpaperViewModel: ObservableObject {
    @Published var query = "nature"
    @Published var sortOrder: SortOrder = .favorites
    @Published var includeGeneral = true
    @Published var includeAnime = true
    @Published var includePeople = true
    @Published var includeSFW = true
    @Published var includeSketchy = false
    @Published var includeNSFW = false
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

    init() {
        loadFavorites()
        loadFolders()
        loadAuth()
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
                statusMessage = "下载中…"
                _ = try await downloader.download(wallpaper)
                statusMessage = "保存成功"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func downloadAndApply(_ wallpaper: WallhavenWallpaper) {
        Task {
            do {
                statusMessage = "下载中…"
                let localURL = try await downloader.download(wallpaper)
                try WallpaperManager.applyWallpaper(from: localURL)
                statusMessage = "壁纸已应用"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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

enum MainTab: String, CaseIterable, Identifiable {
    case home = "首页"
    case favorites = "收藏"
    case local = "本地"
    
    var id: String { rawValue }
}

struct LocalMediaItem: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let creationDate: Date
}

@MainActor
final class LocalMediaViewModel: ObservableObject {
    @Published private(set) var items: [LocalMediaItem] = []
    @Published var errorMessage: String?
    @AppStorage("downloadPath") private var downloadPath: String = {
        return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first?.appendingPathComponent("Wallhaven").path ?? ""
    }()
    
    private var directoryURL: URL? {
        guard !downloadPath.isEmpty else { return nil }
        return URL(fileURLWithPath: downloadPath, isDirectory: true)
    }
    
    func loadMedia() {
        guard let directoryURL else { return }
        
        let fm = FileManager.default
        if !fm.fileExists(atPath: directoryURL.path) {
            items = []
            return
        }
        
        do {
            let urls = try fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)
            var loadedItems: [LocalMediaItem] = []
            for url in urls where ["jpg", "jpeg", "png"].contains(url.pathExtension.lowercased()) {
                let attrs = try url.resourceValues(forKeys: [.creationDateKey])
                let date = attrs.creationDate ?? Date.distantPast
                loadedItems.append(LocalMediaItem(id: UUID(), url: url, creationDate: date))
            }
            items = loadedItems.sorted { $0.creationDate > $1.creationDate }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    func delete(item: LocalMediaItem) {
        do {
            try FileManager.default.removeItem(at: item.url)
            items.removeAll { $0.id == item.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    func applyWallpaper(_ item: LocalMediaItem) {
        do {
            try WallpaperManager.applyWallpaper(from: item.url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var viewModel: WallpaperViewModel
    @StateObject private var localViewModel = LocalMediaViewModel()
    @State private var currentTab: MainTab = .home
    @State private var randomFavoriteBackgroundURL: URL?
    @State private var randomLocalBackgroundURL: URL?
    @State private var selectedLocalItem: LocalMediaItem?
    @State private var isSearchExpanded = false
    @FocusState private var isSearchFocused: Bool
    @State private var viewingWallpaper: WallhavenWallpaper?
    @State private var isShowingNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var pendingFolderWallpaper: WallhavenWallpaper?
    @State private var isRenamingFolder = false
    @State private var renamingFolder: FavoriteFolder?
    @State private var renameFolderName = ""
 
    private let gridHorizontalPadding: CGFloat = 32
    private let gridColumnSpacing: CGFloat = 16
    private let gridRowSpacing: CGFloat = 24
    private let heroRatio: CGFloat = 0.56

    private func gridColumns(for containerWidth: CGFloat) -> [GridItem] {
        let available = containerWidth - (gridHorizontalPadding * 2)
        let minItemWidth: CGFloat = 220
        let count = max(1, min(5, Int((available + gridColumnSpacing) / (minItemWidth + gridColumnSpacing))))
        return Array(
            repeating: GridItem(.flexible(), spacing: gridColumnSpacing),
            count: count
        )
    }

    private var filteredWallpapers: [WallhavenWallpaper] {
        if currentTab == .favorites {
            if let folderID = viewModel.selectedFolderID {
                return viewModel.wallpapersInFolder(folderID)
            }
            return viewModel.favoriteWallpapers
        }
        return viewModel.wallpapers
    }

    private var emptyStateMessage: String {
        if currentTab == .favorites {
            if viewModel.selectedFolderID != nil {
                return "该收藏夹中暂无壁纸。"
            }
            return "暂无收藏。点击任意壁纸上的心形图标即可添加。"
        }
        return "未找到符合当前筛选条件的壁纸。"
    }

    private var activeBackgroundURL: URL? {
        switch currentTab {
        case .home:
            return viewModel.selectedWallpaper?.path ?? viewModel.wallpapers.randomElement()?.path
        case .favorites:
            let favs = viewModel.favoriteWallpapers
            if let selected = viewModel.selectedWallpaper, favs.contains(where: { $0.id == selected.id }) {
                return selected.path
            }
            return randomFavoriteBackgroundURL ?? favs.first?.path ?? viewModel.selectedWallpaper?.path
        case .local:
            if let selected = selectedLocalItem {
                return selected.url
            }
            return randomLocalBackgroundURL ?? localViewModel.items.first?.url ?? viewModel.selectedWallpaper?.path
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let fullSize = CGSize(width: proxy.size.width, height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
            ZStack(alignment: .top) {
                // 背景图延伸到整个窗口（包括标题栏区域）
                WallpaperBackgroundView(url: activeBackgroundURL)
                    .frame(width: fullSize.width, height: fullSize.height)
                    .clipped()
                    .transaction { $0.animation = nil }

                VStack(spacing: 0) {
                    // 顶部留出空间给红绿灯
                    Color.clear.frame(height: proxy.safeAreaInsets.top)
                    
                    detail(in: CGSize(width: proxy.size.width, height: proxy.size.height))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .overlay(alignment: .top) {
                            topBar
                                .padding(.top, 12)
                                .padding(.leading, 80)
                                .padding(.trailing, 16)
                        }
                        .clipped()
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            viewModel.search(reset: true)
            localViewModel.loadMedia()
        }
        .onChange(of: currentTab) {
            if currentTab == .local {
                localViewModel.loadMedia()
                if let randomItem = localViewModel.items.randomElement() {
                    randomLocalBackgroundURL = randomItem.url
                    if selectedLocalItem == nil {
                        selectedLocalItem = randomItem
                    }
                }
            } else if currentTab == .favorites {
                let favs = viewModel.wallpapers.filter { viewModel.isFavorite($0.id) }
                if let randomItem = favs.randomElement() {
                    randomFavoriteBackgroundURL = randomItem.path
                }
            }
        }
        .alert("错误", isPresented: Binding(
            get: { viewModel.errorMessage != nil || localViewModel.errorMessage != nil },
            set: { _ in
                viewModel.errorMessage = nil
                localViewModel.errorMessage = nil
            }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? localViewModel.errorMessage ?? "")
        }
        .sheet(item: $viewingWallpaper) { wallpaper in
            WallpaperDetailView(wallpaper: wallpaper, isFavorite: viewModel.isFavorite(wallpaper.id), onFavorite: {
                viewModel.toggleFavorite(wallpaper)
            })
        }
        .alert("新建收藏夹", isPresented: $isShowingNewFolderAlert) {
            TextField("收藏夹名称", text: $newFolderName)
            Button("取消", role: .cancel) {
                newFolderName = ""
                pendingFolderWallpaper = nil
            }
            Button("创建") {
                let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                let folder = viewModel.createFolder(name: trimmed)
                if let wp = pendingFolderWallpaper {
                    viewModel.addToFolder(wp, folderID: folder.id)
                }
                newFolderName = ""
                pendingFolderWallpaper = nil
            }
        } message: {
            Text("请输入新收藏夹的名称")
        }
        .alert("重命名收藏夹", isPresented: $isRenamingFolder) {
            TextField("收藏夹名称", text: $renameFolderName)
            Button("取消", role: .cancel) {
                renameFolderName = ""
                renamingFolder = nil
            }
            Button("确定") {
                let trimmed = renameFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let folder = renamingFolder, !trimmed.isEmpty {
                    viewModel.renameFolder(folder, to: trimmed)
                }
                renameFolderName = ""
                renamingFolder = nil
            }
        } message: {
            Text("请输入新的名称")
        }
    }

    private var topBar: some View {
        ZStack {
            // ── 中间：导航标签（ZStack 自动居中）
            HStack(spacing: 8) {
                ForEach(MainTab.allCases) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { currentTab = tab }
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(currentTab == tab ? .white : .white.opacity(0.6))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(currentTab == tab ? .white.opacity(0.18) : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(.ultraThinMaterial, in: Capsule())

            // ── 右侧工具栏（叠加在右边，不影响中间居中）
            HStack(spacing: 6) {
                Spacer()

                if currentTab == .home {
                    HStack(spacing: 4) {
                        filterChip(title: "常规", isOn: viewModel.includeGeneral, activeColor: .white.opacity(0.18), textColor: .white, action: viewModel.toggleGeneral)
                        filterChip(title: "动漫", isOn: viewModel.includeAnime,   activeColor: .white.opacity(0.18), textColor: .white, action: viewModel.toggleAnime)
                        filterChip(title: "人物", isOn: viewModel.includePeople,  activeColor: .white.opacity(0.18), textColor: .white, action: viewModel.togglePeople)
                    }
                    .padding(5)
                    .background(.ultraThinMaterial, in: Capsule())

                    HStack(spacing: 4) {
                        filterChip(title: "SFW",     isOn: viewModel.includeSFW,     activeColor: .green.opacity(0.35),  textColor: .green.opacity(0.95),  action: viewModel.toggleSFW)
                        filterChip(title: "Sketchy", isOn: viewModel.includeSketchy, activeColor: .yellow.opacity(0.25), textColor: .yellow.opacity(0.95), disabled: !viewModel.isAuthenticated, action: viewModel.toggleSketchy)
                        filterChip(title: "NSFW",    isOn: viewModel.includeNSFW,    activeColor: .red.opacity(0.25),    textColor: .red.opacity(0.9),     disabled: !viewModel.isAuthenticated, action: viewModel.toggleNSFW)
                    }
                    .padding(5)
                    .background(.ultraThinMaterial, in: Capsule())

                    // 排序 + 搜索
                    HStack(spacing: isSearchExpanded ? 6 : 0) {
                        Menu {
                            ForEach(SortOrder.allCases) { option in
                                Button(option.label) { viewModel.sortOrder = option }
                            }
                        } label: {
                            Text(viewModel.sortOrder.label)
                                .lineLimit(1)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 55)
                        .onChange(of: viewModel.sortOrder) { viewModel.search(reset: true) }

                        Divider().frame(height: 14).opacity(0.4)

                        Button {
                            if isSearchExpanded {
                                viewModel.search(reset: true)
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    isSearchExpanded = true; isSearchFocused = true
                                }
                            }
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.white.opacity(0.8))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.plain)

                        if isSearchExpanded {
                            TextField("搜索壁纸", text: $viewModel.query)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .focused($isSearchFocused)
                                .frame(width: 100)
                                .foregroundStyle(.white)
                                .onSubmit { viewModel.search(reset: true) }
                                .transition(.move(edge: .trailing).combined(with: .opacity))

                            if !viewModel.query.isEmpty {
                                Button {
                                    viewModel.query = ""; viewModel.search(reset: true); isSearchFocused = false
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white.opacity(0.4))
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.plain)
                                .transition(.opacity)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .onChange(of: isSearchFocused) { _, focused in
                        if !focused && viewModel.query.isEmpty && isSearchExpanded {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isSearchExpanded = false }
                        }
                    }

                    SettingsLink {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
                    .help("设置")

                } else if currentTab == .favorites {
                    Menu {
                        Button { viewModel.selectedFolderID = nil } label: {
                            HStack {
                                Text("全部收藏")
                                if viewModel.selectedFolderID == nil { Image(systemName: "checkmark") }
                            }
                        }
                        if !viewModel.favoriteFolders.isEmpty { Divider() }
                        ForEach(viewModel.favoriteFolders) { folder in
                            Button { viewModel.selectedFolderID = folder.id } label: {
                                HStack {
                                    Text("\(folder.name) (\(folder.wallpaperIDs.count))")
                                    if viewModel.selectedFolderID == folder.id { Image(systemName: "checkmark") }
                                }
                            }
                        }
                        Divider()
                        Button {
                            newFolderName = ""; pendingFolderWallpaper = nil; isShowingNewFolderAlert = true
                        } label: { Label("新建收藏夹...", systemImage: "plus") }

                        if let folderID = viewModel.selectedFolderID,
                           let folder = viewModel.favoriteFolders.first(where: { $0.id == folderID }) {
                            Divider()
                            Button {
                                renameFolderName = folder.name; renamingFolder = folder; isRenamingFolder = true
                            } label: { Label("重命名 \"\(folder.name)\"...", systemImage: "pencil") }
                            Button(role: .destructive) {
                                viewModel.deleteFolder(folder)
                            } label: { Label("删除 \"\(folder.name)\"", systemImage: "trash") }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.fill").font(.system(size: 13, weight: .semibold))
                            Text(selectedFolderLabel).lineLimit(1).font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.8))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(minWidth: 80, maxWidth: 140)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .transition(.opacity)
        }
    }

    private var selectedFolderLabel: String {
        if let folderID = viewModel.selectedFolderID,
           let folder = viewModel.favoriteFolders.first(where: { $0.id == folderID }) {
            return folder.name
        }
        return "全部收藏"
    }

    private func filterChip(
        title: String,
        isOn: Bool,
        activeColor: Color,
        textColor: Color,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(disabled ? .gray.opacity(0.75) : (isOn ? textColor : .white.opacity(0.8)))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(isOn ? activeColor : .black.opacity(0.22))
                )
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
    }

    private func detail(in containerSize: CGSize) -> some View {
        return ZStack(alignment: .bottom) {
            if currentTab == .home {
                homeView(in: containerSize)
            } else if currentTab == .local {
                localView(in: containerSize)
            } else {
                favoritesView(in: containerSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.none, value: currentTab)
    }


    // MARK: - Home View (沉浸式大图 + 底部横向滚动条)
    @ViewBuilder
    private func homeView(in containerSize: CGSize) -> some View {
        let thumbH: CGFloat    = max(80, min(150, containerSize.height * 0.15))
        let thumbW: CGFloat    = thumbH * (16.0 / 9.0)
        let stripH: CGFloat    = thumbH + 28
        let thumbCorner: CGFloat = 10
        let cardMaxW: CGFloat  = min(containerSize.width * 0.46, 420)

        ZStack(alignment: .bottom) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)

            // ── 底部整体区域：信息卡片（上） + 缩略图条（下），共用一个 VStack ──
            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                // 信息卡片
                if let wp = viewModel.selectedWallpaper {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("FEATURED")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                            .tracking(2.5)

                        Text("#\(wp.id)")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            Text(wp.category.capitalized)
                            Text("·")
                            Text(wp.resolution)
                            Text("·")
                            HStack(spacing: 3) {
                                Image(systemName: "heart.fill").font(.system(size: 10))
                                Text("\(wp.favorites)")
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))

                        HStack(spacing: 8) {
                            Button { viewModel.downloadAndApply(wp) } label: {
                                HStack(spacing: 5) {
                                    Text("设为壁纸").font(.system(size: 12, weight: .semibold))
                                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundStyle(.black)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(.white, in: Capsule())
                            }
                            .buttonStyle(.plain)

                            // 收藏（可选收藏夹菜单）
                            Menu {
                                if !viewModel.favoriteFolders.isEmpty {
                                    ForEach(viewModel.favoriteFolders) { folder in
                                        let inFolder = viewModel.foldersContaining(wp.id).map(\.id).contains(folder.id)
                                        Button {
                                            inFolder
                                                ? viewModel.removeFromFolder(wp.id, folderID: folder.id)
                                                : viewModel.addToFolder(wp, folderID: folder.id)
                                        } label: {
                                            Label(folder.name,
                                                  systemImage: inFolder ? "checkmark.circle.fill" : "folder")
                                        }
                                    }
                                    Divider()
                                }
                                Button(role: viewModel.isFavorite(wp.id) ? .destructive : nil) {
                                    viewModel.toggleFavorite(wp)
                                } label: {
                                    Label(viewModel.isFavorite(wp.id) ? "取消收藏" : "添加到默认收藏",
                                          systemImage: viewModel.isFavorite(wp.id) ? "heart.slash" : "heart")
                                }
                            } label: {
                                Image(systemName: viewModel.isFavorite(wp.id) ? "heart.fill" : "heart")
                                    .font(.system(size: 15))
                                    .foregroundStyle(viewModel.isFavorite(wp.id) ? Color.pink : .white)
                                    .frame(width: 32, height: 32)
                                    .background(.white.opacity(0.18), in: Circle())
                                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()

                            Button { viewModel.downloadImage(wp) } label: {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.white)
                                    .frame(width: 32, height: 32)
                                    .background(.white.opacity(0.18), in: Circle())
                                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: thumbCorner + 4, style: .continuous)
                            .fill(.black.opacity(0.45))
                            .overlay(
                                RoundedRectangle(cornerRadius: thumbCorner + 4, style: .continuous)
                                    .stroke(.white.opacity(0.12), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                    .frame(maxWidth: cardMaxW, alignment: .leading)
                }

                // 缩略图横向滚动条
                if !viewModel.wallpapers.isEmpty || viewModel.isLoading {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(viewModel.wallpapers) { item in
                                KFImage(item.thumbURL ?? item.path)
                                    .placeholder { Color.white.opacity(0.08) }
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: thumbW, height: thumbH)
                                    .clipShape(RoundedRectangle(cornerRadius: thumbCorner, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: thumbCorner, style: .continuous)
                                            .stroke(
                                                viewModel.selectedWallpaper?.id == item.id
                                                    ? Color.white : Color.white.opacity(0.2),
                                                lineWidth: viewModel.selectedWallpaper?.id == item.id ? 2.5 : 1
                                            )
                                    )
                                    .scaleEffect(viewModel.selectedWallpaper?.id == item.id ? 1.04 : 1.0)
                                    .animation(.spring(response: 0.3), value: viewModel.selectedWallpaper?.id)
                                    .onTapGesture {
                                        withAnimation(.easeInOut(duration: 0.3)) {
                                            viewModel.selectedWallpaper = item
                                        }
                                        viewModel.loadMoreIfNeeded(current: item)
                                    }
                                    .contextMenu {
                                        Button("设为壁纸") { viewModel.downloadAndApply(item) }
                                        Button(viewModel.isFavorite(item.id) ? "取消收藏" : "添加收藏") {
                                            viewModel.toggleFavorite(item)
                                        }
                                        Button("下载") { viewModel.downloadImage(item) }
                                        Divider()
                                        Button("在浏览器中打开") { NSWorkspace.shared.open(item.url) }
                                    }
                                    .onAppear { viewModel.loadMoreIfNeeded(current: item) }
                            }
                            if viewModel.isLoading {
                                ProgressView().tint(.white)
                                    .frame(width: thumbW * 0.4, height: thumbH)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .frame(height: stripH)
                    // ✅ 给 ScrollView 加同等圆角，边缘半截图保持圆角而非直角裁剪
                    .clipShape(RoundedRectangle(cornerRadius: thumbCorner, style: .continuous))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ThumbnailScrollMonitor(stripHeight: stripH + 14)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }


    // MARK: - Favorites View（与首页相同的沉浸式布局）
    @ViewBuilder
    private func favoritesView(in containerSize: CGSize) -> some View {
        let items      = filteredWallpapers
        let selected   = viewModel.selectedWallpaper
        let thumbH: CGFloat    = max(80, min(150, containerSize.height * 0.15))
        let thumbW: CGFloat    = thumbH * (16.0 / 9.0)
        let stripH: CGFloat    = thumbH + 28
        let thumbCorner: CGFloat = 10
        let cardMaxW: CGFloat  = min(containerSize.width * 0.46, 420)

        ZStack(alignment: .bottom) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)

            if items.isEmpty, !viewModel.isLoading {
                // 空状态
                VStack(spacing: 12) {
                    Image(systemName: "heart.slash")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(emptyStateMessage)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                    Button("浏览壁纸") { withAnimation { currentTab = .home } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer()

                    // 信息卡片
                    if let wp = selected, items.contains(where: { $0.id == wp.id }) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("FAVORITES")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.55))
                                .tracking(2.5)

                            Text("#\(wp.id)")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            HStack(spacing: 8) {
                                Text(wp.category.capitalized)
                                Text("·")
                                Text(wp.resolution)
                                Text("·")
                                HStack(spacing: 3) {
                                    Image(systemName: "heart.fill").font(.system(size: 10))
                                    Text("\(wp.favorites)")
                                }
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.65))

                            HStack(spacing: 8) {
                                Button { viewModel.downloadAndApply(wp) } label: {
                                    HStack(spacing: 5) {
                                        Text("设为壁纸").font(.system(size: 12, weight: .semibold))
                                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                                    }
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(.white, in: Capsule())
                                }
                                .buttonStyle(.plain)

                                Menu {
                                    if !viewModel.favoriteFolders.isEmpty {
                                        ForEach(viewModel.favoriteFolders) { folder in
                                            let inFolder = viewModel.foldersContaining(wp.id).map(\.id).contains(folder.id)
                                            Button {
                                                inFolder
                                                    ? viewModel.removeFromFolder(wp.id, folderID: folder.id)
                                                    : viewModel.addToFolder(wp, folderID: folder.id)
                                            } label: {
                                                Label(folder.name, systemImage: inFolder ? "checkmark.circle.fill" : "folder")
                                            }
                                        }
                                        Divider()
                                    }
                                    Button(role: .destructive) { viewModel.toggleFavorite(wp) } label: {
                                        Label("取消收藏", systemImage: "heart.slash")
                                    }
                                } label: {
                                    Image(systemName: "heart.fill")
                                        .font(.system(size: 15))
                                        .foregroundStyle(Color.pink)
                                        .frame(width: 32, height: 32)
                                        .background(.white.opacity(0.18), in: Circle())
                                        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()

                                Button { viewModel.downloadImage(wp) } label: {
                                    Image(systemName: "arrow.down.circle")
                                        .font(.system(size: 15))
                                        .foregroundStyle(.white)
                                        .frame(width: 32, height: 32)
                                        .background(.white.opacity(0.18), in: Circle())
                                        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(20)
                        .background(
                            RoundedRectangle(cornerRadius: thumbCorner + 4, style: .continuous)
                                .fill(.black.opacity(0.45))
                                .overlay(RoundedRectangle(cornerRadius: thumbCorner + 4, style: .continuous)
                                    .stroke(.white.opacity(0.12), lineWidth: 1))
                        )
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                        .frame(maxWidth: cardMaxW, alignment: .leading)
                    }

                    // 缩略图横向滚动条
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(items) { item in
                                KFImage(item.thumbURL ?? item.path)
                                    .placeholder { Color.white.opacity(0.08) }
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: thumbW, height: thumbH)
                                    .clipShape(RoundedRectangle(cornerRadius: thumbCorner, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: thumbCorner, style: .continuous)
                                            .stroke(
                                                selected?.id == item.id ? Color.white : Color.white.opacity(0.2),
                                                lineWidth: selected?.id == item.id ? 2.5 : 1
                                            )
                                    )
                                    .scaleEffect(selected?.id == item.id ? 1.04 : 1.0)
                                    .animation(.spring(response: 0.3), value: selected?.id)
                                    .onTapGesture {
                                        withAnimation(.easeInOut(duration: 0.3)) {
                                            viewModel.selectedWallpaper = item
                                            randomFavoriteBackgroundURL = item.path
                                        }
                                    }
                                    .contextMenu {
                                        Button("设为壁纸") { viewModel.downloadAndApply(item) }
                                        Button("取消收藏") { viewModel.toggleFavorite(item) }
                                        Button("下载") { viewModel.downloadImage(item) }
                                        Divider()
                                        Button("在浏览器中打开") { NSWorkspace.shared.open(item.url) }
                                    }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .frame(height: stripH)
                    .clipShape(RoundedRectangle(cornerRadius: thumbCorner, style: .continuous))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ThumbnailScrollMonitor(stripHeight: stripH + 14)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // 自动选中第一项
            if viewModel.selectedWallpaper == nil || !items.contains(where: { $0.id == viewModel.selectedWallpaper?.id }) {
                if let first = items.first {
                    viewModel.selectedWallpaper = first
                    randomFavoriteBackgroundURL = first.path
                }
            }
        }
    }

    // MARK: - Local View（与首页相同的沉浸式布局）
    @ViewBuilder
    private func localView(in containerSize: CGSize) -> some View {
        let thumbH: CGFloat    = max(80, min(150, containerSize.height * 0.15))
        let thumbW: CGFloat    = thumbH * (16.0 / 9.0)
        let stripH: CGFloat    = thumbH + 28
        let thumbCorner: CGFloat = 10
        let cardMaxW: CGFloat  = min(containerSize.width * 0.46, 420)

        ZStack(alignment: .bottom) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)

            if localViewModel.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("本地没有已下载的壁纸")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer()

                    // 信息卡片
                    if let item = selectedLocalItem {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("LOCAL")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.55))
                                .tracking(2.5)

                            Text(item.url.deletingPathExtension().lastPathComponent)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(2)

                            HStack(spacing: 8) {
                                if let size = try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                    Text("·")
                                }
                                Text(item.url.pathExtension.uppercased())
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.65))

                            HStack(spacing: 8) {
                                Button { localViewModel.applyWallpaper(item) } label: {
                                    HStack(spacing: 5) {
                                        Text("设为壁纸").font(.system(size: 12, weight: .semibold))
                                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                                    }
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(.white, in: Capsule())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                } label: {
                                    Image(systemName: "folder")
                                        .font(.system(size: 15))
                                        .foregroundStyle(.white)
                                        .frame(width: 32, height: 32)
                                        .background(.white.opacity(0.18), in: Circle())
                                        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                                }
                                .buttonStyle(.plain)

                                Button {
                                    localViewModel.delete(item: item)
                                    selectedLocalItem = localViewModel.items.first
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 15))
                                        .foregroundStyle(.red.opacity(0.85))
                                        .frame(width: 32, height: 32)
                                        .background(.white.opacity(0.18), in: Circle())
                                        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(20)
                        .background(
                            RoundedRectangle(cornerRadius: thumbCorner + 4, style: .continuous)
                                .fill(.black.opacity(0.45))
                                .overlay(RoundedRectangle(cornerRadius: thumbCorner + 4, style: .continuous)
                                    .stroke(.white.opacity(0.12), lineWidth: 1))
                        )
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                        .frame(maxWidth: cardMaxW, alignment: .leading)
                    }

                    // 缩略图横向滚动条
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(localViewModel.items) { item in
                                Group {
                                    if let nsImg = NSImage(contentsOf: item.url) {
                                        Image(nsImage: nsImg)
                                            .resizable()
                                            .scaledToFill()
                                    } else {
                                        Color.white.opacity(0.08)
                                    }
                                }
                                .frame(width: thumbW, height: thumbH)
                                .clipShape(RoundedRectangle(cornerRadius: thumbCorner, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: thumbCorner, style: .continuous)
                                        .stroke(
                                            selectedLocalItem?.id == item.id ? Color.white : Color.white.opacity(0.2),
                                            lineWidth: selectedLocalItem?.id == item.id ? 2.5 : 1
                                        )
                                )
                                .scaleEffect(selectedLocalItem?.id == item.id ? 1.04 : 1.0)
                                .animation(.spring(response: 0.3), value: selectedLocalItem?.id)
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        selectedLocalItem = item
                                    }
                                }
                                .contextMenu {
                                    Button("设为壁纸") { localViewModel.applyWallpaper(item) }
                                    Button("在 Finder 中显示") {
                                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                    }
                                    Divider()
                                    Button("删除", role: .destructive) {
                                        localViewModel.delete(item: item)
                                        if selectedLocalItem?.id == item.id {
                                            selectedLocalItem = localViewModel.items.first
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .frame(height: stripH)
                    .clipShape(RoundedRectangle(cornerRadius: thumbCorner, style: .continuous))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ThumbnailScrollMonitor(stripHeight: stripH + 14)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

/// 全局拦截滚轮 + 鼠标拖动事件：
///  - 在缩略图条区域内，把垂直滚轮转换为水平滚动
///  - 在缩略图条区域内，左键拖动实现横向拖动滚动
private struct ThumbnailScrollMonitor: NSViewRepresentable {
    let stripHeight: CGFloat

    class Coordinator {
        var monitor: Any?
        // 拖动状态
        var mouseDownInStrip = false
        var isDragScrolling   = false
        var mouseDownX: CGFloat = 0
        var scrollOriginX: CGFloat = 0

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coord = context.coordinator
        if let old = coord.monitor { NSEvent.removeMonitor(old); coord.monitor = nil }

        let h = stripHeight
        coord.monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak coord] event in
            guard let coord else { return event }

            switch event.type {

            // ── 鼠标滚轮 ───────────────────────────────────
            case .scrollWheel:
                guard let window = event.window else { return event }
                let loc = event.locationInWindow
                guard loc.y < h else { return event }
                guard let sv = Self.findHScrollView(in: window.contentView) else { return event }

                let dx = event.scrollingDeltaX
                let dy = event.scrollingDeltaY
                let delta: CGFloat = abs(dx) >= abs(dy) ? -dx : dy
                let mult: CGFloat  = event.hasPreciseScrollingDeltas ? 1.0 : 10.0

                Self.scroll(sv, by: delta * mult)
                return nil  // 消耗事件

            // ── 鼠标左键按下 ───────────────────────────────
            case .leftMouseDown:
                guard let window = event.window else { return event }
                let loc = event.locationInWindow
                if loc.y < h {
                    coord.mouseDownInStrip = true
                    coord.isDragScrolling  = false
                    coord.mouseDownX       = loc.x
                    // 记录当前 scroll 位置作为起点
                    if let sv = Self.findHScrollView(in: window.contentView) {
                        coord.scrollOriginX = sv.contentView.bounds.origin.x
                    }
                } else {
                    coord.mouseDownInStrip = false
                }
                return event  // 保留，让 tap 正常触发

            // ── 鼠标左键拖动 ───────────────────────────────
            case .leftMouseDragged:
                guard coord.mouseDownInStrip,
                      let window = event.window else { return event }
                let loc   = event.locationInWindow
                let moved = coord.mouseDownX - loc.x   // 向右拖为正

                // 超过 5pt 阈值才切换为拖动滚动模式
                if !coord.isDragScrolling && abs(moved) < 5 { return event }
                coord.isDragScrolling = true

                guard let sv = Self.findHScrollView(in: window.contentView) else { return event }
                let contentW = sv.documentView?.frame.width ?? 0
                let viewW    = sv.frame.width
                let maxX     = max(0, contentW - viewW)
                let newX     = max(0, min(maxX, coord.scrollOriginX + moved))

                sv.contentView.scroll(to: NSPoint(x: newX, y: 0))
                sv.reflectScrolledClipView(sv.contentView)
                return nil  // 消耗拖动事件，防止触发其他行为

            // ── 鼠标左键抬起 ───────────────────────────────
            case .leftMouseUp:
                coord.mouseDownInStrip = false
                coord.isDragScrolling  = false
                return event

            default:
                return event
            }
        }
    }

    private static func scroll(_ sv: NSScrollView, by delta: CGFloat) {
        let currentX = sv.contentView.bounds.origin.x
        let contentW = sv.documentView?.frame.width ?? 0
        let maxX     = max(0, contentW - sv.frame.width)
        let newX     = max(0, min(maxX, currentX - delta))
        sv.contentView.scroll(to: NSPoint(x: newX, y: 0))
        sv.reflectScrolledClipView(sv.contentView)
    }

    /// 深度遍历，找出内容比面板宽的水平 NSScrollView
    private static func findHScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let sv = view as? NSScrollView,
           !sv.isHidden,
           let docW = sv.documentView?.frame.width,
           docW > sv.frame.width + 20 {
            return sv
        }
        for sub in view.subviews {
            if let found = findHScrollView(in: sub) { return found }
        }
        return nil
    }
}




private struct WallpaperBackgroundView: View, Equatable {
    let url: URL?

    static func == (lhs: WallpaperBackgroundView, rhs: WallpaperBackgroundView) -> Bool {
        lhs.url == rhs.url
    }

    var body: some View {
        if let url {
            if url.isFileURL, let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
            } else {
                KFImage(url)
                    .placeholder {
                        Rectangle().fill(Color.black)
                    }
                    .onFailure { _ in
                        // Do nothing, placeholder will stay
                    }
                    .resizable()
                    .scaledToFill()
            }
        } else {
            Color.black
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var viewModel: WallpaperViewModel
    @AppStorage("downloadPath") private var downloadPath: String = {
        let defaultPath = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first?.appendingPathComponent("Wallhaven").path ?? ""
        return defaultPath
    }()
    @State private var selectedTab = 0
    @StateObject private var updateManager = UpdateManager()
    
    private let tabs: [(String, String)] = [
        ("常规", "gearshape.fill"),
        ("账户", "person.crop.circle.fill"),
        ("关于", "info.circle.fill")
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部标签栏
            HStack(spacing: 4) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTab = index
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.1)
                                .font(.system(size: 12))
                            Text(tab.0)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(selectedTab == index ? .white : .secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(selectedTab == index ? Color.accentColor.opacity(0.85) : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .padding(.top, 18)
            .padding(.bottom, 10)
            
            Divider().opacity(0.5)
            
            // 内容区
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch selectedTab {
                    case 0: generalContent
                    case 1: accountContent
                    case 2: aboutContent
                    default: EmptyView()
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 520, height: 460)
    }
    
    // MARK: - 常规
    
    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsSectionHeader(icon: "arrow.down.circle.fill", title: "下载设置", color: .blue)
            
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("保存路径")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue.opacity(0.8))
                                .font(.system(size: 13))
                            Text(downloadPath)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.primary.opacity(0.85))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                        
                        Button("更改...") {
                            selectDownloadFolder()
                        }
                        .controlSize(.small)
                    }
                    
                    Text("下载的壁纸将保存在此文件夹中。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
    
    // MARK: - 账户
    
    private var accountContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsSectionHeader(icon: "key.fill", title: "Wallhaven 账户", color: .orange)
            
            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    settingsField(label: "API 密钥", systemImage: "lock.fill") {
                        SecureField("输入您的 API 密钥", text: $viewModel.apiKeyInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                    }
                    
                    settingsField(label: "用户名", systemImage: "person.fill") {
                        TextField("输入您的用户名", text: $viewModel.usernameInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                    }
                    
                    HStack(spacing: 8) {
                        Button {
                            viewModel.login()
                        } label: {
                            Text(viewModel.isAuthenticated ? "更新配置" : "登录验证")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        
                        Button("获取 API 密钥") {
                            viewModel.openAPIKeyPage()
                        }
                        .controlSize(.small)
                        
                        if viewModel.isAuthenticated {
                            Spacer()
                            Button("退出登录") {
                                viewModel.logout()
                            }
                            .controlSize(.small)
                            .foregroundStyle(.red.opacity(0.85))
                        }
                    }
                    .padding(.top, 2)
                    
                    Text("登录后可访问 NSFW 内容，配置用户名后可同步线上收藏夹到本地。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            
            if viewModel.isAuthenticated {
                settingsSectionHeader(icon: "arrow.triangle.2.circlepath", title: "收藏同步", color: .green)
                
                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Button {
                                Task {
                                    await viewModel.syncCollections()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "icloud.and.arrow.down")
                                        .font(.system(size: 12))
                                    Text("同步线上收藏到本地")
                                        .font(.system(size: 12, weight: .medium))
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.green.opacity(0.85))
                            .disabled(viewModel.isSyncing)
                            
                            if viewModel.isSyncing {
                                ProgressView()
                                    .controlSize(.small)
                                Text(viewModel.syncProgress)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        
                        Text("将云端收藏夹结构同步到本地。考虑到 API 速率限制（45次/分钟），收藏较多时耐心等待。")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
    
    // MARK: - 关于
    
    private var aboutContent: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 20)
            
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApplication.shared.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 18))
            
            VStack(spacing: 6) {
                Text("Wallhaven")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("版本 \(version)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Capsule())
                }
            }
            
            Text("非官方 Wallhaven macOS 客户端")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            
            Link(destination: URL(string: "https://wallhaven.cc")!) {
                HStack(spacing: 5) {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                    Text("访问 Wallhaven 官网")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            
            // 更新检查区域
            VStack(spacing: 12) {
                Button(action: {
                    Task { await updateManager.checkForUpdates() }
                }) {
                    HStack {
                        if updateManager.isChecking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.swap")
                        }
                        Text(updateManager.isChecking ? "正在检查..." : "检查更新")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(updateManager.isChecking || updateManager.isDownloading)
                
                if updateManager.updateAvailable {
                    VStack(spacing: 8) {
                        Text("发现新版本: v\(updateManager.latestVersion)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.green)
                        
                        if updateManager.isDownloading {
                            ProgressView("正在自动更新...")
                                .controlSize(.small)
                                .font(.system(size: 11))
                                .padding(.top, 4)
                        } else {
                            Button(action: {
                                updateManager.downloadAndInstall()
                            }) {
                                Text("立即更新并重启")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(Color.blue)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 24)
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                }
                
                if let errorMsg = updateManager.errorMessage {
                    Text(errorMsg)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
            .padding(.top, 10)
            
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - 复用组件
    
    private func settingsSectionHeader(icon: String, title: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
        }
    }
    
    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
    
    private func settingsField<Content: View>(label: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary.opacity(0.7))
                    .font(.system(size: 12))
                    .frame(width: 16)
                content()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }
    
    private func selectDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择下载目录"
        
        if panel.runModal() == .OK {
            if let newPath = panel.url?.path {
                let oldPath = downloadPath
                guard newPath != oldPath else { return }
                
                // 迁移旧目录下的文件到新目录
                let fm = FileManager.default
                let oldURL = URL(fileURLWithPath: oldPath, isDirectory: true)
                let newURL = URL(fileURLWithPath: newPath, isDirectory: true)
                
                if fm.fileExists(atPath: oldPath) {
                    do {
                        // 确保新目录存在
                        if !fm.fileExists(atPath: newPath) {
                            try fm.createDirectory(at: newURL, withIntermediateDirectories: true)
                        }
                        
                        let files = try fm.contentsOfDirectory(at: oldURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                        for file in files {
                            let dest = newURL.appendingPathComponent(file.lastPathComponent)
                            if !fm.fileExists(atPath: dest.path) {
                                try fm.moveItem(at: file, to: dest)
                            }
                        }
                        
                        // 如果旧目录已清空则删除
                        let remaining = try fm.contentsOfDirectory(at: oldURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                        if remaining.isEmpty {
                            try? fm.removeItem(at: oldURL)
                        }
                    } catch {
                        // 迁移失败不阻断路径切换，仅打印日志
                        print("文件迁移失败: \(error.localizedDescription)")
                    }
                }
                
                downloadPath = newPath
            }
        }
    }
}

struct LocalMediaCard: View {
    let item: LocalMediaItem
    let isSelected: Bool
    let onTap: () -> Void
    let onSetAsWallpaper: () -> Void
    let onDelete: () -> Void
    let onShowInFinder: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear
                .aspectRatio(16/10, contentMode: .fit)
                .overlay {
                    if let nsImage = NSImage(contentsOf: item.url) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .overlay {
                                Image(systemName: "photo")
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isSelected ? Color.white : Color.white.opacity(0.08), lineWidth: isSelected ? 3 : 1)
                )

            HStack {
                Text(item.url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
            }
            .padding(.horizontal, 4)
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
            Button("设为壁纸") { onSetAsWallpaper() }
            Button("在访达中显示") { onShowInFinder() }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Text("删除")
            }
        }
    }
}


struct WallpaperCard: View {
    let wallpaper: WallhavenWallpaper
    let selectedID: String?
    let isFavorite: Bool
    let folders: [FavoriteFolder]
    let containingFolders: [FavoriteFolder]
    let onTap: () -> Void
    let onFavorite: () -> Void
    let onSetAsWallpaper: () -> Void
    let onDownload: () -> Void
    let onShowDetails: () -> Void
    let onAddToFolder: (UUID) -> Void
    let onRemoveFromFolder: (UUID) -> Void
    let onNewFolder: () -> Void

    private var isSelected: Bool {
        selectedID == wallpaper.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear
                .aspectRatio(16/10, contentMode: .fit)
                .overlay {
                    KFImage(wallpaper.thumbURL ?? wallpaper.path)
                        .placeholder {
                            Rectangle()
                                .fill(Color.white.opacity(0.08))
                                .overlay { ProgressView().tint(.white) }
                        }
                        .resizable()
                        .scaledToFill()
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isSelected ? .blue : .white.opacity(0.08), lineWidth: isSelected ? 2 : 1)
                )

            HStack {
                Text(wallpaper.resolution)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()

                Button {
                    onFavorite()
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(isFavorite ? .red : .white.opacity(0.8))
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 6)
        }
        .padding(.bottom, 8)
        .background(Color.white.opacity(1e-5))
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .contextMenu {
            Button("查看详情") { onShowDetails() }
            Button("设为壁纸") { onSetAsWallpaper() }
            Button("下载原图") { onDownload() }
            Divider()
            Button(isFavorite ? "取消收藏" : "收藏") { onFavorite() }
            
            if !folders.isEmpty {
                Menu("收藏到收藏夹...") {
                    ForEach(folders) { folder in
                        let isInFolder = containingFolders.contains(where: { $0.id == folder.id })
                        Button {
                            if isInFolder {
                                onRemoveFromFolder(folder.id)
                            } else {
                                onAddToFolder(folder.id)
                            }
                        } label: {
                            HStack {
                                Text(folder.name)
                                if isInFolder {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    Divider()
                    Button {
                        onNewFolder()
                    } label: {
                        Label("新建收藏夹...", systemImage: "plus")
                    }
                }
            } else {
                Button {
                    onNewFolder()
                } label: {
                    Label("新建收藏夹并收藏", systemImage: "folder.badge.plus")
                }
            }
        }
        .scaleEffect(isSelected ? 0.98 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}

#Preview {
    ContentView()
        .environmentObject(WallpaperViewModel())
}

struct WallpaperDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let wallpaper: WallhavenWallpaper
    let isFavorite: Bool
    let onFavorite: () -> Void
    @State private var tags: [String] = []
    @State private var isLoadingTags = true
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("壁纸详情")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            Color.black
                .overlay {
                    KFImage(wallpaper.path)
                        .placeholder {
                            ProgressView()
                        }
                        .resizable()
                        .scaledToFit()
                }
            
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("分辨率: \(wallpaper.resolution)")
                    Text("宽高比: \(wallpaper.ratio)")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text("分类: \(wallpaper.category)")
                    Text("纯净度: \(wallpaper.purity)")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                
                Button {
                    onFavorite()
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(isFavorite ? .red : .primary)
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .padding(.leading, 10)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
        }
        /*
        .overlay(alignment: .bottom) {
            if isLoadingTags {
                ProgressView()
                    .padding()
            } else if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.15))
                                .clipShape(Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    .padding()
                }
                .background(Color.black.opacity(0.6))
            }
        }
        */
        .frame(width: 800, height: 600)
        /*
        .task {
            let client = WallhavenClient()
            let apiKey = UserDefaults.standard.string(forKey: "wallper.wallhaven.apikey")
            do {
                tags = try await client.fetchWallpaperDetails(id: wallpaper.id, apiKey: apiKey)
            } catch {
                print(error)
            }
            isLoadingTags = false
        }
        */
    }
}
//
//  UpdateManager.swift
//  wallhaven
//

import Foundation
import AppKit

@MainActor
class UpdateManager: ObservableObject {
    @Published var isChecking = false
    @Published var updateAvailable = false
    @Published var latestVersion = ""
    @Published var releaseNotes = ""
    @Published var downloadURL: URL?
    
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var errorMessage: String?

    // 请将此处替换为你的实际 GitHub 仓库，例如："用户名/仓库名"
    private let githubRepo = "RoaycL/wallhaven"
    
    func checkForUpdates() async {
        isChecking = true
        errorMessage = nil
        defer { isChecking = false }
        
        let urlString = "https://api.github.com/repos/\(githubRepo)/releases/latest"
        guard let url = URL(string: urlString) else { return }
        
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return
            }
            
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let latestVer = release.tag_name.replacingOccurrences(of: "v", with: "")
            
            let currentVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            
            if isNewerVersion(latestVer, currentVersion: currentVer) {
                self.latestVersion = latestVer
                self.releaseNotes = release.body ?? ""
                // 查找 zip 或 dmg 下载链接
                if let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) {
                    self.downloadURL = URL(string: asset.browser_download_url)
                }
                self.updateAvailable = true
            }
        } catch {
            print("检查更新失败: \(error)")
            // self.errorMessage = "检查更新失败: \(error.localizedDescription)"
        }
    }
    
    func downloadAndInstall() {
        guard let downloadURL = downloadURL else { return }
        
        isDownloading = true
        errorMessage = nil
        downloadProgress = 0.0
        
        Task {
            do {
                let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)
                self.isDownloading = false
                try self.installUpdate(from: tempURL)
            } catch {
                self.isDownloading = false
                self.errorMessage = "下载或安装过程出错: \(error.localizedDescription)"
            }
        }
    }
    
    private func installUpdate(from zipURL: URL) throws {
        let fileManager = FileManager.default
        
        // 1. 创建临时解压目录
        let tempExtractURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempExtractURL, withIntermediateDirectories: true)
        
        // 2. 解压
        let unzipProcess = Process()
        unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzipProcess.arguments = ["-q", zipURL.path, "-d", tempExtractURL.path]
        try unzipProcess.run()
        unzipProcess.waitUntilExit()
        
        if unzipProcess.terminationStatus != 0 {
            throw NSError(domain: "UpdateManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "解压缩失败"])
        }
        
        // 3. 找到解压出的 .app
        let contents = try fileManager.contentsOfDirectory(at: tempExtractURL, includingPropertiesForKeys: nil)
        guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
            throw NSError(domain: "UpdateManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "更新包中未找到应用程序"])
        }
        
        // 4. 获取当前 App 路径
        guard let currentAppPath = Bundle.main.bundlePath as String? else {
            throw NSError(domain: "UpdateManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "找不到当前应用安装路径"])
        }
        let currentAppURL = URL(fileURLWithPath: currentAppPath)
        
        // 5. 替换应用程序 (如果当前在 只读镜像 中，此步会失败)。
        let backupURL = currentAppURL.deletingPathExtension().appendingPathExtension("old.app")
        if fileManager.fileExists(atPath: backupURL.path) {
            try? fileManager.removeItem(at: backupURL)
        }
        
        // 将旧版移动到 backup 路径 (为了安全替换)
        do {
            try fileManager.moveItem(at: currentAppURL, to: backupURL)
            try fileManager.copyItem(at: appURL, to: currentAppURL)
            
            // 删除备份及临时文件
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.removeItem(at: tempExtractURL)
            try? fileManager.removeItem(at: zipURL)
            
        } catch {
            // 回滚
            if fileManager.fileExists(atPath: backupURL.path) && !fileManager.fileExists(atPath: currentAppURL.path) {
                try? fileManager.moveItem(at: backupURL, to: currentAppURL)
            }
            throw error
        }
        
        // 6. 重启
        relaunchApp()
    }
    
    private func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundlePath]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }
    
    private func isNewerVersion(_ latest: String, currentVersion: String) -> Bool {
        return latest.compare(currentVersion, options: .numeric) == .orderedDescending
    }
}

struct GitHubRelease: Decodable {
    let tag_name: String
    let body: String?
    let assets: [GitHubAsset]
}

struct GitHubAsset: Decodable {
    let name: String
    let browser_download_url: String
}