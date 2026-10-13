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
        case online = "在线"

        var id: String { rawValue }
    }

    @Published var mode: Mode = .library
    @Published private(set) var libraryItems: [WorkshopItem] = []
    @Published private(set) var onlineItems: [WorkshopItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var downloading: Set<String> = []

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
    }

    private let api = SteamWorkshopAPI()
    private let toast = ToastCenter.shared
    private var cursor: String?
    private var webPage = 1
    private var canLoadMore = true
    private var searchTask: Task<Void, Never>?
    private var filterDebounce: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        apiKey = defaults.string(forKey: Keys.apiKey) ?? ""
        steamUsername = defaults.string(forKey: Keys.username) ?? ""
        filters = defaults.data(forKey: Keys.filters).flatMap { try? JSONDecoder().decode(WorkshopFilters.self, from: $0) } ?? WorkshopFilters()
        extraFolders = (defaults.stringArray(forKey: Keys.folders) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    var hasAPIKey: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }
    var steamCMDPath: URL? { SteamCMDDownloader.locate() }

    /// 已下载模式在本地按关键词和筛选条件过滤；在线模式由服务端过滤
    var items: [WorkshopItem] {
        mode == .library ? libraryItems.filter { filters.matches($0, query: query) } : onlineItems
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

    /// 把在线条目标记为已下载（关联本地文件夹）
    private func mergeDownloadState() {
        let local = Dictionary(libraryItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        onlineItems = onlineItems.map { item in
            var item = item
            if let localItem = local[item.id] {
                item.localFolder = localItem.localFolder
                item.entryFile = localItem.entryFile
            } else {
                item.localFolder = nil
            }
            return item
        }
    }

    func delete(_ item: WorkshopItem) {
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
        guard mode == .online, let index = onlineItems.firstIndex(of: item), index >= onlineItems.count - 6 else { return }
        search(reset: false)
    }

    // MARK: - Download / Apply

    func download(_ item: WorkshopItem, applyWhenDone: Bool = false) {
        guard !downloading.contains(item.id) else { return }
        guard item.type.isPlayable else {
            toast.show("「应用」类型的壁纸是 Windows 程序，无法在 macOS 上运行", style: .error)
            return
        }
        downloading.insert(item.id)
        toast.show("正在通过 steamcmd 下载「\(item.title)」…", style: .progress)

        Task {
            defer { downloading.remove(item.id) }
            do {
                let folder = try await SteamCMDDownloader.shared.download(id: item.id, username: steamUsername)
                // steamcmd 的下载目录不在库里时（自定义安装路径），把它的上级目录加入库
                let root = folder.deletingLastPathComponent()
                if !libraryRoots.contains(where: { $0.standardizedFileURL == root.standardizedFileURL }) {
                    setExtraFolders(extraFolders + [root])
                }
                let items = await Task.detached { [roots = libraryRoots] in WorkshopLibrary.scan(roots: roots) }.value
                libraryItems = items
                mergeDownloadState()
                toast.show("「\(item.title)」下载完成", style: .success)

                if applyWhenDone, let downloaded = libraryItems.first(where: { $0.id == item.id }) {
                    apply(downloaded)
                }
            } catch {
                toast.show(error.localizedDescription, style: .error)
            }
        }
    }

    func cancelDownload(_ item: WorkshopItem) {
        SteamCMDDownloader.shared.cancel(item.id)
    }

    func apply(_ item: WorkshopItem) {
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
