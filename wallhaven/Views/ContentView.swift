//
//  ContentView.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import AppKit
import Kingfisher
import SwiftUI
import Combine

/// 顶部页签：按用途组织，两个来源（Wallhaven / 创意工坊）在每个页签里一致
enum MainTab: String, CaseIterable, Identifiable {
    case discover = "发现"
    case collections = "收藏"
    case library = "资料库"
    case playlists = "播放列表"

    var id: String { rawValue }
}

/// 「发现」「收藏」页签里的来源切换
enum ContentSource: String, CaseIterable, Identifiable {
    case wallhaven = "Wallhaven"
    case workshop = "创意工坊"

    var id: String { rawValue }
}

/// 收藏的来源筛选：全部合并 Wallhaven 收藏与创意工坊订阅。
enum CollectionSource: String, CaseIterable, Identifiable {
    case all = "全部"
    case wallhaven = "Wallhaven"
    case workshop = "创意工坊"

    var id: String { rawValue }
}

/// 页签 + 来源决定实际显示的画廊页面
private enum GalleryPage: Equatable {
    case home, favorites, workshop, library, playlists
}

struct ContentView: View {
    @EnvironmentObject private var viewModel: WallpaperViewModel
    @EnvironmentObject private var workshop: WorkshopViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ThemePalette { ThemePalette(scheme: colorScheme) }
    @StateObject private var localViewModel = LocalMediaViewModel()
    @StateObject private var immersive = ImmersiveWindowController()
    @State private var galleryTimer = Timer.publish(every: GalleryAutoplayState.interval, on: .main, in: .common).autoconnect()
    @ObservedObject private var toastCenter = ToastCenter.shared
    @ObservedObject private var liveController = LiveWallpaperController.shared

    @State private var currentTab: MainTab = .discover
    @AppStorage("ui.discoverSource") private var discoverSource: ContentSource = .wallhaven
    @State private var collectionSource: CollectionSource = .all
    @State private var favoriteSelectionID: String?
    @State private var localSelectionID: String?
    @State private var librarySource: LibrarySource = .all
    @State private var libraryQuery = ""
    @State private var topBarTabsWidth: CGFloat = 0
    @State private var topBarTrailingWidth: CGFloat = 0
    /// 只有主动选择/导航才要求缩略图滚动；删除后的邻项选择保留当前视口。
    @State private var selectionWithoutScrollingID: String?
    /// 自动轮播切换的选中项：缩略图条把它滚到正中；手动点选和键盘浏览只在看不到时才滚动
    @State private var centersSelection = false
    @State private var workshopSelectionID: String?
    @State private var isWorkshopFilterPresented = false
    @State private var workshopColumns = 4
    /// 背景只在有新选中项时更新：搜索重置、列表清空期间保持上一张，不会跳到随机图
    @State private var backgroundItem: GalleryItem?
    @State private var displayedBackgroundItem: GalleryItem?
    @State private var failedBackgroundID: String?
    /// 删除动画：正在收起的缩略图；被删除、正在淡出的大图（下一张显示出来后清除）
    @State private var removingIDs: Set<String> = []
    @State private var dismissedBackgroundID: String?
    /// 页面级加载提示（统一显示在顶部栏下方）；加载很快时不显示，避免闪一下
    @State private var showsPageLoading = false
    /// 创意工坊网格的底部是否露出（用户滑到底、在等下一页）
    @State private var isWorkshopFooterVisible = false
    @State private var backgroundRetryToken = 0
    @State private var playlistKeyHandler: ((ImmersiveWindowController.Key) -> Bool)?
    @State private var prefetcher: ImagePrefetcher?
    @State private var isFilterPresented = false
    @State private var isDownloadsPresented = false
    @State private var isSearchExpanded = false

    @State private var isShowingNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var isRenamingFolder = false
    @State private var renamingFolder: FavoriteFolder?
    @State private var renameFolderName = ""

    // MARK: - Data

    private var page: GalleryPage {
        switch currentTab {
        case .discover: discoverSource == .wallhaven ? .home : .workshop
        case .collections: collectionSource == .workshop ? .workshop : .favorites
        case .library: .library
        case .playlists: .playlists
        }
    }

    /// 工坊网格的数据随页签切换：发现 = 在线，收藏 = 已订阅
    private func syncWorkshopMode() {
        guard page == .workshop || currentTab == .collections else { return }
        let mode: WorkshopViewModel.Mode = currentTab == .discover ? .online : .subscribed
        if workshop.mode != mode { workshop.mode = mode }
    }

    /// 资料库：已下载的 wallhaven 壁纸、导入的图片和视频、已下载的工坊壁纸
    private var libraryItems: [GalleryItem] {
        let local = localViewModel.items.map { GalleryItem(origin: .local($0)) }
        let workshopItems = workshop.libraryItems.map { GalleryItem(origin: .workshop($0)) }
        // 按下载 / 导入时间排序，最新的在最前
        return (local + workshopItems)
            .filter { librarySource.matches($0) && $0.matchesLibrarySearch(libraryQuery) }
            .sorted { $0.addedDate > $1.addedDate }
    }

    /// 已下载到本地的 wallhaven 壁纸 ID（文件名就是 ID）。下载后资料库刷新，角标随之更新
    private var downloadedWallhavenIDs: Set<String> { localViewModel.wallhavenIDs }

    private func items(for page: GalleryPage) -> [GalleryItem] {
        switch page {
        case .home:
            return viewModel.wallpapers.map { GalleryItem(origin: .remote($0)) }
        case .favorites:
            // 全部不受单个来源里保留的收藏夹、搜索词和工坊筛选影响。
            let wallpapers = collectionSource == .all ? viewModel.favoriteWallpapers
                : (viewModel.selectedFolderID.map(viewModel.wallpapersInFolder) ?? viewModel.favoriteWallpapers)
            let favorites = wallpapers.reversed().map { GalleryItem(origin: .remote($0)) }
            return collectionSource == .all
                ? favorites + workshop.subscribedItems.map { GalleryItem(origin: .workshop($0)) }
                : favorites
        case .workshop:
            return workshop.items.map { GalleryItem(origin: .workshop($0)) }
        case .library:
            return libraryItems
        case .playlists:
            return []
        }
    }

    private func selectedID(for page: GalleryPage) -> String? {
        switch page {
        case .home: viewModel.selectedWallpaper.map { GalleryItem(origin: .remote($0)).id }
        case .favorites: favoriteSelectionID
        case .workshop: workshopSelectionID
        case .library: localSelectionID
        case .playlists: nil
        }
    }

    private var currentItems: [GalleryItem] { items(for: page) }

    private var selectedItem: GalleryItem? {
        guard let id = selectedID(for: page) else { return nil }
        return currentItems.first { $0.id == id }
    }

    private var actionableItem: GalleryItem? {
        guard let selectedItem else { return nil }
        return displayedBackgroundItem?.id == selectedItem.id || failedBackgroundID == selectedItem.id ? selectedItem : nil
    }

    private var displayedInfoItem: GalleryItem? {
        if let selectedItem, failedBackgroundID == selectedItem.id { return selectedItem }
        guard let displayedBackgroundItem else { return nil }
        return currentItems.first { $0.id == displayedBackgroundItem.id } ?? displayedBackgroundItem
    }

    private func select(_ item: GalleryItem, isUserInitiated: Bool = false) {
        if isUserInitiated { immersive.userDidSelectThumbnail() }
        selectionWithoutScrollingID = nil
        centersSelection = false
        switch page {
        case .home: viewModel.selectedWallpaper = item.remote
        case .favorites: favoriteSelectionID = item.id
        case .workshop: workshopSelectionID = item.id
        case .library: localSelectionID = item.id
        case .playlists: break
        }
    }

    /// 选中项不在列表里时重新选择：
    /// 若是被移除（取消订阅 / 取消收藏 / 删除），选原位置的下一项（没有则上一项），并保持滚动位置；
    /// 若整个列表换了（搜索、筛选、切换页面），回到第一项
    private func ensureValidSelection(previousIDs: [String] = []) {
        let items = currentItems
        guard !items.isEmpty, selectedItem == nil else { return }

        if let removedID = selectedID(for: page),
           let neighborID = SelectionFallback.neighbor(of: removedID, previousIDs: previousIDs, currentIDs: items.map(\.id)),
           let neighbor = items.first(where: { $0.id == neighborID }) {
            select(neighbor)
            selectionWithoutScrollingID = neighborID
            return
        }
        if let first = items.first {
            select(first)
        }
    }

    private func moveSelection(by offset: Int) {
        let items = currentItems
        guard !items.isEmpty else { return }
        let index = selectedItem.flatMap { item in items.firstIndex(of: item) } ?? 0
        let newIndex = max(0, min(items.count - 1, index + offset))
        let item = items[newIndex]
        select(item, isUserInitiated: true)
        if page == .home, let wallpaper = item.remote {
            viewModel.loadMoreIfNeeded(current: wallpaper)
        }
        if page == .workshop, let workshopItem = item.workshop {
            workshop.loadMoreIfNeeded(current: workshopItem)
        }
    }

    /// 预加载前后相邻的原图，方便 ←/→ 快速切换
    private func prefetchNeighbors(of item: GalleryItem) {
        let items = currentItems
        guard let index = items.firstIndex(of: item) else { return }
        // 循环播放时也预加载第一张；本地图片与在线原图使用同一处理和缓存配置。
        var seen: Set<String> = [item.id]
        let sources = [1, 2, -1].compactMap { offset -> Source? in
            let candidate = items[(index + offset + items.count) % items.count]
            guard seen.insert(candidate.id).inserted,
                  candidate.remote != nil || (candidate.local != nil && !candidate.isVideo) else { return nil }
            return candidate.fullSource
        }
        guard !sources.isEmpty else { return }
        prefetcher?.stop()
        let newPrefetcher = ImagePrefetcher(sources: sources, options: ImageSizing.backgroundOptions)
        newPrefetcher.maxConcurrentDownloads = 2
        newPrefetcher.start()
        prefetcher = newPrefetcher
    }

    // MARK: - Actions

    private func apply(_ item: GalleryItem) {
        switch item.origin {
        case .remote(let wallpaper): viewModel.downloadAndApply(wallpaper)
        case .local(let local): localViewModel.applyWallpaper(local)
        case .workshop(let workshopItem): workshop.apply(workshopItem)
        }
    }

    private func deleteLocal(_ item: LocalMediaItem) {
        deleteFromLibrary(GalleryItem(origin: .local(item)), unsubscribe: false)
    }

    /// 删除（移到废纸篓）。删除选中项后选中原位置的邻项由 ensureValidSelection 统一处理。
    /// 先播放收起动画：缩略图缩小淡出、两侧合拢；删的是当前大图时，大图和信息栏一起下沉淡出，
    /// 动画结束再真正删除，下一张随后对焦淡入
    private func deleteFromLibrary(_ item: GalleryItem, unsubscribe: Bool) {
        guard item.remote == nil, !removingIDs.contains(item.id) else { return }
        // 只有大图正显示着这张时才淡出大图；它还在加载中时，屏幕上是别的图，不用动
        let isShowing = item.id == displayedBackgroundItem?.id
        let collapse: Animation = Motion.reducesMotion ? .easeOut(duration: 0.15) : .easeIn(duration: 0.26)
        withAnimation(collapse) {
            removingIDs.insert(item.id)
            if isShowing { dismissedBackgroundID = item.id }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(Motion.reducesMotion ? 150 : 260))
            withAnimation(Motion.navigation) {
                switch item.origin {
                case .local(let local): localViewModel.delete(item: local)
                case .workshop(let workshopItem): workshop.delete(workshopItem, unsubscribe: unsubscribe)
                case .remote: break
                }
            }
            removingIDs.remove(item.id)
            // 删除失败（文件被占用等）时条目还在：恢复显示
            if currentItems.contains(where: { $0.id == item.id }), dismissedBackgroundID == item.id {
                withAnimation(Motion.content) { dismissedBackgroundID = nil }
            }
        }
    }

    /// 需要告诉用户「在加载」的时候：第一次加载、刷新，或者已经滑到底在等下一页。
    /// 后台预加载下一页不打扰（每页约 1 秒，否则往下翻时提示会一个接一个出现）
    private var isPageLoading: Bool {
        if page == .home, viewModel.isLoading {
            return viewModel.wallpapers.isEmpty || viewModel.isRefreshing
        }
        if page == .workshop, workshop.mode == .online, workshop.isLoading {
            return workshop.onlineItems.isEmpty || workshop.isRefreshing || isWorkshopFooterVisible
        }
        return false
    }

    private var isPageRefreshing: Bool {
        // 已有旧结果时才算「刷新」；第一次加载显示「正在加载」
        (page == .home && viewModel.isRefreshing && !viewModel.wallpapers.isEmpty)
            || (page == .workshop && workshop.isRefreshing && !workshop.onlineItems.isEmpty)
    }

    /// 创意工坊网格页显示界面时，背景换成窗口后方的磨砂玻璃（隐藏界面时仍显示选中壁纸的预览）
    private var isGridGlass: Bool { isWorkshopGrid && !immersive.isChromeHidden }

    private var hasOpenPanel: Bool { isFilterPresented || isWorkshopFilterPresented || isDownloadsPresented }

    private func handleKey(_ key: ImmersiveWindowController.Key) -> Bool {
        if hasOpenPanel {
            if key == .escape { closeAllPanels(); return true }
            return false
        }
        if page == .playlists, let playlistKeyHandler, playlistKeyHandler(key) { return true }
        if page == .playlists, [.left, .right, .up, .down, .enter].contains(key) { return false }
        switch key {
        case .left:
            moveSelection(by: -1)
        case .right:
            moveSelection(by: 1)
        case .up:
            // 网格页面按行移动
            guard let columns = gridColumns else { return false }
            moveSelection(by: -columns)
        case .down:
            guard let columns = gridColumns else { return false }
            moveSelection(by: columns)
        case .enter:
            guard let item = actionableItem else { return false }
            apply(item)
        case .character("d"):
            guard let wallpaper = actionableItem?.remote else { return false }
            viewModel.downloadImage(wallpaper)
        case .character("l"):
            guard let wallpaper = actionableItem?.remote else { return false }
            viewModel.toggleFavorite(wallpaper)
        case .character("/"):
            guard hasSearch else { return false }
            openSearch()
        case .character("1"): switchTab(.discover)
        case .character("2"): switchTab(.collections)
        case .character("3"): switchTab(.library)
        case .character("4"): switchTab(.playlists)
        default:
            return false
        }
        return true
    }

    /// 只有「发现 · 创意工坊」（在线小方图）用网格，其他页面都是沉浸式大图
    private var isWorkshopGrid: Bool {
        page == .workshop && currentTab == .discover
    }

    private var gridColumns: Int? {
        isWorkshopGrid ? workshopColumns : nil
    }

    private var hasSearch: Bool {
        page == .home || page == .workshop || page == .library
    }

    /// 提供给顶部菜单栏的操作
    private var commandActions: GalleryCommandActions {
        let item = actionableItem
        let canDownload: Bool = switch item?.origin {
        case .remote: true
        case .workshop(let workshopItem): !workshopItem.isDownloaded && workshopItem.type.isPlayable
        default: false
        }
        return GalleryCommandActions(
            currentTab: currentTab,
            hasSelection: item != nil,
            canDownload: canDownload,
            canFavorite: item?.remote != nil,
            isFavorite: item?.remote.map { viewModel.isFavorite($0.id) } ?? false,
            canOpenInBrowser: item?.remote != nil || item?.workshop?.workshopPageURL != nil,
            hasSearch: hasSearch,
            isChromeHidden: immersive.isChromeHidden,
            apply: { if let item { apply(item) } },
            download: {
                switch item?.origin {
                case .remote(let wallpaper): viewModel.downloadImage(wallpaper)
                case .workshop(let workshopItem): workshop.download(workshopItem)
                default: break
                }
            },
            toggleFavorite: { if let wallpaper = item?.remote { viewModel.toggleFavorite(wallpaper) } },
            move: { moveSelection(by: $0) },
            toggleChrome: { immersive.toggleChrome() },
            switchTab: { switchTab($0) },
            focusSearch: {
                openSearch()
            },
            openInBrowser: {
                if let url = item?.remote?.url ?? item?.workshop?.workshopPageURL {
                    NSWorkspace.shared.open(url)
                }
            },
            importLocal: {
                switchTab(.library)
                localViewModel.importFiles()
            },
            addWorkshopFolder: {
                switchTab(.library)
                workshop.addLibraryFolder()
            }
        )
    }

    private func handleMenuNavigation() {
        if let id = MainWindow.requestedWorkshopItemID {
            MainWindow.requestedWorkshopItemID = nil
            revealWorkshopItem(id)
            return
        }
        if let id = MainWindow.requestedSubscribedItemID {
            MainWindow.requestedSubscribedItemID = nil
            revealSubscribedItem(id)
            return
        }
        guard let tab = MainWindow.requestedTab else { return }
        MainWindow.requestedTab = nil
        switchTab(tab)
        if tab == .library {
            localViewModel.loadMedia()
            workshop.refreshLibrary()
        }
    }

    /// 下载任务点击跳转：本地还在就到「资料库 · 创意工坊」选中它，已删除就到「发现 · 创意工坊」按 ID 查询
    private func revealWorkshopItem(_ id: String) {
        // 和鼠标点选一样：暂停画廊的自动轮播，不让跳转过来的壁纸几秒后被换掉
        immersive.userDidSelectThumbnail()
        let selectionID = GalleryItem(origin: .workshop(WorkshopItem(id: id, title: "", type: .unknown, tags: []))).id
        if workshop.libraryItems.contains(where: { $0.id == id }) {
            librarySource = .workshop
            libraryQuery = ""
            switchTab(.library)
            localSelectionID = selectionID
        } else {
            discoverSource = .workshop
            switchTab(.discover)
            workshop.mode = .online
            workshop.query = id
            workshop.search(reset: true)
            workshopSelectionID = selectionID
        }
    }

    /// 订阅同步失败提示点击跳转：到「收藏 · 创意工坊」（已订阅）选中这个条目，详情栏显示它的信息
    private func revealSubscribedItem(_ id: String) {
        immersive.userDidSelectThumbnail()
        switchTab(.collections)
        collectionSource = .workshop
        syncWorkshopMode()
        // 搜索词会过滤已订阅列表，清掉才能看到它
        if !workshop.query.isEmpty { workshop.query = "" }
        guard workshop.subscribedItems.contains(where: { $0.id == id }) else { return }
        workshopSelectionID = GalleryItem(origin: .workshop(WorkshopItem(id: id, title: "", type: .unknown, tags: []))).id
        if !workshop.items.contains(where: { $0.id == id }) {
            toastCenter.show("当前筛选条件隐藏了这个条目，重置筛选后可见", style: .info)
        }
    }

    private func restartGalleryCountdown() {
        immersive.restartGalleryCountdown()
        // 重建订阅使下一次触发距离现在满五秒；控制器的截止时间也会拦住旧的排队事件。
        galleryTimer = Timer.publish(every: GalleryAutoplayState.interval, on: .main, in: .common).autoconnect()
    }

    private func switchTab(_ tab: MainTab) {
        restartGalleryCountdown()
        withAnimation(Motion.navigation) {
            if tab == .collections, currentTab != .collections { collectionSource = .all }
            currentTab = tab
        }
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .top) {
                // 未下载的工坊条目：网格页的预览在详情栏里；沉浸式页面平时把卡片放在右上，隐藏界面后居中
                // 大图还没显示（刚打开、删除后的间隙）时垫在下面的磨砂底，代替纯黑
                FrostedBackdrop(item: backgroundItem)
                    .frame(width: size.width, height: size.height)
                    .opacity(displayedBackgroundItem == nil || dismissedBackgroundID != nil ? 1 : 0)
                    .animation(Motion.content, value: displayedBackgroundItem == nil || dismissedBackgroundID != nil)
                    .allowsHitTesting(false)

                ImmersiveBackground(
                    item: backgroundItem,
                    showsPreviewCard: isWorkshopGrid ? immersive.isChromeHidden : true,
                    centersPreviewCard: isWorkshopGrid || immersive.isChromeHidden,
                    showsBlackBase: false,
                    onDisplayed: {
                        displayedBackgroundItem = $0
                        restartGalleryCountdown()
                        failedBackgroundID = nil
                        if $0.id != dismissedBackgroundID { dismissedBackgroundID = nil }
                    },
                    onFailed: {
                        if $0.id == selectedItem?.id {
                            failedBackgroundID = $0.id
                            restartGalleryCountdown()
                        }
                        if $0.id != dismissedBackgroundID { withAnimation(Motion.content) { dismissedBackgroundID = nil } }
                    },
                    retryToken: backgroundRetryToken,
                    // 播放列表页、创意工坊网格页背景被盖住，不再运行动态渲染
                    staticOnly: page == .playlists || isGridGlass
                )
                    .frame(width: size.width, height: size.height)
                    // 删除当前壁纸：大图略微缩小、模糊并淡出，下一张就绪后再淡入
                    .scaleEffect(dismissedBackgroundID != nil && !Motion.reducesMotion ? 0.96 : 1)
                    .blur(radius: dismissedBackgroundID != nil && !Motion.reducesMotion ? 14 : 0)
                    .opacity(dismissedBackgroundID != nil || isGridGlass ? 0 : 1)
                    // 播放列表页：背景虚化，面板成为主体。opaque：边缘保持不透明，
                    // 否则模糊会让窗口边缘变成半透明，透出后面的其他窗口，四周显得发虚
                    .blur(radius: page == .playlists && !Motion.reducesMotion ? 18 : 0, opaque: page == .playlists)
                    .animation(Motion.navigation, value: page == .playlists)
                    // 沉浸式页面双击图片：隐藏 / 显示界面，只看图片细节（同空格键）
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard !isWorkshopGrid, page != .playlists else { return }
                        immersive.toggleChrome()
                    }

                // 创意工坊网格页：背景是窗口后方的磨砂玻璃，透出当前桌面壁纸；
                // 缩略图还没加载出来的卡片也是半透明的，同样能看到这层玻璃
                ScenaWindowGlass(material: .popover)
                    .overlay(palette.scrim.opacity(palette.isDay ? 0.10 : 0.18))
                    .frame(width: size.width, height: size.height)
                    .opacity(isGridGlass ? 1 : 0)
                    .animation(Motion.navigation, value: isGridGlass)
                    .allowsHitTesting(false)

                // 播放列表页：虚化的背景上再轻轻压一层，面板更突出
                if page == .playlists {
                    palette.scrim.opacity(immersive.isChromeHidden ? 0 : (palette.isDay ? 0.16 : 0.26))
                        .allowsHitTesting(false)
                }

                // 上下渐变只为大图页面的文字服务；播放列表页的面板和顶部栏自带背景，不再叠加
                scrims(height: size.height)
                    .opacity(immersive.isChromeHidden || isGridGlass || page == .playlists ? 0 : (displayedBackgroundItem == nil ? 0.4 : 1))
                    .allowsHitTesting(false)

                gallery(in: size)
                    .frame(width: size.width, height: size.height)
                    .opacity(immersive.isChromeHidden ? 0 : 1)
                    .offset(y: immersive.isChromeHidden && !Motion.reducesMotion ? 24 : 0)
                    .allowsHitTesting(!immersive.isChromeHidden)

                VStack(spacing: 12) {
                    topBar(width: size.width)
                        // 兜底：即使放不下也只裁掉边缘，不会撑宽父视图、把整个界面推歪露出白边
                        .frame(width: size.width)
                        // 只裁左右（防止窄窗口时把界面撑宽）；上下留出空间，按钮角标不会被切掉
                        .mask(Rectangle().padding(.vertical, -40))
                        .opacity(immersive.isChromeHidden ? 0 : 1)
                        .offset(y: immersive.isChromeHidden && !Motion.reducesMotion ? -12 : 0)
                        .allowsHitTesting(!immersive.isChromeHidden)
                }
                .padding(.top, 10)

                // 提示条放在右上角顶部栏下方，不随界面隐藏
                // 页面级加载（搜索、筛选、翻页）统一显示在顶部栏下方居中
                VStack {
                    if showsPageLoading {
                        PageLoadingCapsule(title: isPageRefreshing ? "正在刷新" : "正在加载")
                            .transition(Motion.reducesMotion ? .opacity : .opacity.combined(with: .offset(y: -6)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, topBarInset + 8)
                .opacity(immersive.isChromeHidden ? 0 : 1)
                .allowsHitTesting(false)
                .task(id: isPageLoading) {
                    guard isPageLoading else {
                        // 稍后再收起：紧接着的下一次加载（如首屏铺不满时自动加载第二页）连成一次，不会一闪一闪
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        withAnimation(Motion.content) { showsPageLoading = false }
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled, isPageLoading else { return }
                    withAnimation(Motion.content) { showsPageLoading = true }
                }

                VStack {
                    if let toast = toastCenter.current {
                        ToastView(toast: toast)
                            .frame(maxWidth: 380, alignment: .trailing)
                            .transition(Motion.reducesMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                            .onTapGesture {
                                toast.action?()
                                toastCenter.dismiss()
                            }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, topBarInset + 8)
                .padding(.trailing, 16)

            }
            .overlayPreferenceValue(PanelTriggerKey.self) { triggers in
                panelOverlay(triggers: triggers, size: size)
            }
        }
        .ignoresSafeArea()
        // 最小尺寸要放得下顶部栏最宽的情况（页签 + 来源切换 + 搜索、筛选等工具），否则内容会把整个界面挤歪
        .frame(minWidth: 1120, minHeight: 640)
        .background(WindowAccessor { immersive.attach(to: $0) })
        .focusedSceneValue(\.galleryActions, commandActions)
        .onAppear {
            restartGalleryCountdown()
            MainWindow.opener = { openWindow(id: MainWindow.id) }
            immersive.keyHandler = handleKey
            immersive.allowsChromeKeyboardShortcuts = { !hasOpenPanel && page != .playlists }
            immersive.allowsDragScrolling = { page != .playlists }
            handleMenuNavigation()
            syncWorkshopMode()
            viewModel.search(reset: true)
            localViewModel.loadMedia()
            workshop.refreshLibrary()
            // 已登录 Steam 时同步订阅（10 分钟内不重复）
            workshop.syncSubscriptions()
        }
        .onReceive(galleryTimer) { _ in
            guard !isWorkshopGrid, page != .playlists, !(page == .home && viewModel.isLoading),
                  actionableItem != nil, currentItems.count > 1, immersive.canAdvanceGallery else { return }
            let index = selectedItem.flatMap { currentItems.firstIndex(of: $0) } ?? -1
            select(currentItems[(index + 1) % currentItems.count])
            centersSelection = true
        }
        .onReceive(NotificationCenter.default.publisher(for: MainWindow.navigationNotification)) { _ in
            handleMenuNavigation()
        }
        .onChange(of: currentTab) { isSearchExpanded = false }
        .onChange(of: page) {
            isSearchExpanded = false
            restartGalleryCountdown()
            selectionWithoutScrollingID = nil
            syncWorkshopMode()
            if page == .library {
                localViewModel.loadMedia()
                workshop.refreshLibrary()
            }
            if page == .workshop {
                workshop.refreshLibrary()
                workshop.syncSubscriptions()
            }
            closeAllPanels()
            ensureValidSelection()
        }
        .onChange(of: workshop.mode) {
            if workshop.mode == .online, workshop.onlineItems.isEmpty { workshop.search(reset: true) }
            if workshop.mode == .subscribed { workshop.syncSubscriptions() }
        }
        .onChange(of: workshop.filters) { workshop.filtersDidChange() }
        .onChange(of: isWorkshopFilterPresented) { _, presented in immersive.setHold("workshopFilter", active: presented) }
        .onChange(of: currentItems.map(\.id), initial: true) { oldIDs, _ in
            ensureValidSelection(previousIDs: oldIDs)
        }
        .onChange(of: discoverSource) { restartGalleryCountdown() }
        .onChange(of: collectionSource) { restartGalleryCountdown() }
        .onChange(of: librarySource) { restartGalleryCountdown() }
        .onChange(of: viewModel.selectedFolderID) { restartGalleryCountdown() }
        .onChange(of: selectedItem?.id) {
            failedBackgroundID = nil
            restartGalleryCountdown()
        }
        .onChange(of: selectedItem, initial: true) { _, item in
            guard let item else { return }
            backgroundItem = item
            prefetchNeighbors(of: item)
        }
        .task(id: selectedItem?.remote?.id) {
            // 防抖：快速切换时不会对每一张都请求详情接口（API 有频率限制）
            guard let wallpaper = selectedItem?.remote else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await viewModel.loadTagsIfNeeded(for: wallpaper)
            // 顺带预取下一张的标签，切过去时标签和标题一起出现（详情接口有频率限制，只取一张）
            let items = currentItems
            if let index = items.firstIndex(where: { $0.remote?.id == wallpaper.id }), items.count > 1,
               let next = items[(index + 1) % items.count].remote {
                guard !Task.isCancelled else { return }
                await viewModel.loadTagsIfNeeded(for: next)
            }
        }
        .onChange(of: viewModel.sortOrder) { viewModel.search(reset: true, debounce: true) }
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message else { return }
            toastCenter.show(message, style: .error)
            viewModel.errorMessage = nil
        }
        .onChange(of: isSearchExpanded) { _, expanded in immersive.setHold("search", active: expanded) }
        .onChange(of: isFilterPresented) { _, presented in immersive.setHold("filter", active: presented) }
        .onChange(of: isShowingNewFolderAlert || isRenamingFolder) { _, shown in immersive.setHold("alert", active: shown) }
        .alert("新建收藏夹", isPresented: $isShowingNewFolderAlert) {
            TextField("收藏夹名称", text: $newFolderName)
            Button("取消", role: .cancel) { newFolderName = "" }
            Button("创建") {
                let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { _ = viewModel.createFolder(name: trimmed) }
                newFolderName = ""
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

    /// 筛选 / 下载面板浮层：从触发按钮的位置「长」出来，点击面板外部关闭
    @ViewBuilder
    private func panelOverlay(triggers: [PanelTrigger: Anchor<CGRect>], size: CGSize) -> some View {
        GeometryReader { proxy in
            let open: (kind: PanelTrigger, width: CGFloat)? =
                isDownloadsPresented ? (.downloads, 440)
                : isWorkshopFilterPresented ? (.workshopFilter, 360)
                : isFilterPresented ? (.filter, 300) : nil
            if let open {
                let button = triggers[open.kind].map { proxy[$0] }
                    ?? CGRect(x: size.width - 40, y: 16, width: 34, height: 34)
                let top = button.maxY + 10
                let panelMinX = size.width - 16 - open.width
                // 缩放锚点落在按钮正下方，面板像从按钮里伸展出来
                let anchor = UnitPoint(x: min(max((button.midX - panelMinX) / open.width, 0), 1), y: 0)
                ZStack(alignment: .topTrailing) {
                    Color.black.opacity(0.001)
                        .onTapGesture { closeAllPanels() }
                    Group {
                        switch open.kind {
                        case .downloads: WorkshopDownloadsView(onNavigate: { closeAllPanels() })
                        case .workshopFilter: WorkshopFilterPanel(maxHeight: size.height - top - 24)
                        case .filter: FilterPanel()
                        }
                    }
                    .padding(.top, top)
                    .padding(.trailing, 16)
                    .transition(.panelGrow(from: anchor))
                    .id(open.kind)
                }
                .transition(.identity)
            }
        }
    }

    private func closeAllPanels() {
        withAnimation(Motion.panel) {
            isFilterPresented = false
            isWorkshopFilterPresented = false
            isDownloadsPresented = false
        }
    }

    /// 上下渐变暗角，保证文字在任何壁纸上都可读
    private func scrims(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            // 只保证文字可读，尽量少压壁纸：日间白色更显眼，比夜间再淡一些
            LinearGradient(colors: [palette.scrim.opacity(palette.isDay ? 0.38 : 0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 110)
            Spacer(minLength: 0)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: palette.scrim.opacity(palette.isDay ? 0.26 : 0.32), location: 0.45),
                    .init(color: palette.scrim.opacity(palette.isDay ? 0.58 : 0.62), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: height * 0.55)
        }
    }

    // MARK: - Top bar

    /// 顶部栏占用的高度，供贴着顶部栏排列的内容使用（来源切换已并入主页签，顶部栏只有一行）
    private var topBarInset: CGFloat { 58 }

    /// 顶部栏：主页签和下方的二级切换一起居中；窗口太窄放不下时回退为靠左排列，避免与右侧工具重叠
    private func topBar(width: CGFloat) -> some View {
        let leadingInset: CGFloat = 80 // 红绿灯
        let trailingInset: CGFloat = 16
        let gap: CGFloat = 12
        let halfTabs = topBarTabsWidth / 2
        let canCenter = topBarTabsWidth > 0
            && width / 2 - halfTabs - gap >= leadingInset
            && width / 2 + halfTabs + gap <= width - trailingInset - topBarTrailingWidth

        return ZStack(alignment: .top) {
            HStack(alignment: .top, spacing: 10) {
                if !canCenter { navigation }
                Spacer(minLength: 12)
                topBarTrailing
                    .measureWidth($topBarTrailingWidth)
            }
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)

            if canCenter { navigation }
        }
        .animation(Motion.navigation, value: canCenter)
        .onHover { immersive.setHold("topbar", active: $0) }
    }

    private var navigation: some View { mainTabs }

    /// 主页签。选中的页签如果有来源（发现、收藏、资料库），显示成「资料库 · 创意工坊 ▾」，点击弹出来源菜单
    private var mainTabs: some View {
        HStack(spacing: 2) {
            ForEach(MainTab.allCases) { tab in
                if currentTab == tab, let source = sourceTitle(for: tab) {
                    Menu {
                        sourcePicker(for: tab)
                    } label: {
                        HStack(spacing: 5) {
                            Text(tab.rawValue)
                            if !source.isEmpty {
                                Text("·").foregroundStyle(Color.primary.opacity(0.45))
                                Text(source).foregroundStyle(Color.primary.opacity(0.85))
                            }
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.primary.opacity(0.6))
                        }
                        .modifier(MainTabLabel(isSelected: true))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("切换来源")
                    // 不做交叉淡化：新旧标签叠在一起会出现重影，由底色滑动表现切换
                    .transition(.identity)
                    .anchorPreference(key: SelectedTabAnchorKey.self, value: .bounds) { $0 }
                } else {
                    Button { switchTab(tab) } label: {
                        Text(tab.rawValue).modifier(MainTabLabel(isSelected: currentTab == tab))
                    }
                    .buttonStyle(.plain)
                    .transition(.identity)
                    .anchorPreference(key: SelectedTabAnchorKey.self, value: .bounds) { currentTab == tab ? $0 : nil }
                }
            }
        }
        // 选中底色画在页签行的背景里，跟随选中页签的位置和宽度滑动、伸缩
        .backgroundPreferenceValue(SelectedTabAnchorKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor {
                    let frame = proxy[anchor]
                    Capsule()
                        .fill(palette.selection)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .padding(4)
        .sceneGlass(in: Capsule())
        .measureWidth($topBarTabsWidth)
        .animation(Motion.navigation, value: currentTab)
    }

    /// 页签上显示的当前来源；nil 表示这个页签没有来源可选
    private func sourceTitle(for tab: MainTab) -> String? {
        switch tab {
        case .discover: discoverSource.rawValue
        case .collections: collectionSource == .all ? "" : collectionSource.rawValue
        case .library: librarySource == .all ? "" : librarySource.rawValue
        case .playlists: nil
        }
    }

    @ViewBuilder
    private func sourcePicker(for tab: MainTab) -> some View {
        switch tab {
        case .discover:
            Picker("来源", selection: $discoverSource) {
                ForEach(ContentSource.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
        case .collections:
            Picker("来源", selection: $collectionSource) {
                ForEach(CollectionSource.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
        case .library:
            Picker("来源", selection: $librarySource) {
                ForEach(LibrarySource.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
        case .playlists:
            EmptyView()
        }
    }

    @ViewBuilder
    private var topBarTrailing: some View {
        HStack(spacing: 10) {
            LiveWallpaperStatus(controller: liveController)
            WorkshopDownloadsButton(isPresented: Binding(
                get: { isDownloadsPresented },
                set: { open in
                    isDownloadsPresented = open
                    if open { isFilterPresented = false; isWorkshopFilterPresented = false }
                }
            ))
            .anchorPreference(key: PanelTriggerKey.self, value: .bounds) { [.downloads: $0] }

            switch page {
            case .home:
                searchField
                filterButton
            case .favorites:
                if collectionSource == .wallhaven { folderMenu }
            case .library:
                librarySearchField
                libraryAddMenu
            case .playlists:
                EmptyView()
            case .workshop:
                workshopSearchField
                workshopFilterButton
                if workshop.mode == .subscribed, workshop.isLoggedIn {
                    Button { workshop.syncSubscriptions(force: true) } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.85))
                            .rotationEffect(.degrees(workshop.isSyncing && !Motion.reducesMotion ? 360 : 0))
                            .animation(workshop.isSyncing ? Motion.syncing : Motion.hover, value: workshop.isSyncing)
                            .frame(width: 34, height: 34)
                            .sceneGlass(in: Circle(), interactive: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(workshop.isSyncing)
                    .help("与 Steam 同步订阅")
                }
            }

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .sceneGlass(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .help("设置")
        }
    }

    private func openSearch() {
        guard hasSearch else { return }
        immersive.showChrome()
        isSearchExpanded = true
    }

    private var librarySearchField: some View {
        CollapsibleSearchField(
            title: "搜索资料库", query: $libraryQuery, isExpanded: $isSearchExpanded,
            onSubmit: {}, onClear: { libraryQuery = "" }
        )
    }

    private var libraryAddMenu: some View {
        Menu {
            Button("导入图片或视频…") { localViewModel.importFiles() }
            Button("添加 Wallpaper Engine 文件夹…") { workshop.addLibraryFolder() }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.85))
                .frame(width: 34, height: 34)
                .sceneGlass(in: Circle(), interactive: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("添加到资料库")
    }

    private var searchField: some View {
        CollapsibleSearchField(
            title: "搜索壁纸", query: $viewModel.query, isExpanded: $isSearchExpanded,
            onSubmit: { viewModel.search(reset: true) },
            onClear: {
                viewModel.query = ""
                viewModel.search(reset: true)
            }
        )
    }

    private var workshopSearchField: some View {
        CollapsibleSearchField(
            title: workshop.mode == .online ? "搜索工坊或粘贴链接" : "搜索订阅",
            query: $workshop.query, isExpanded: $isSearchExpanded,
            onSubmit: {
                // 订阅列表实时过滤，在线搜索在提交时发起请求。
                if workshop.mode == .online { workshop.search(reset: true) }
            },
            onClear: {
                workshop.query = ""
                if workshop.mode == .online { workshop.search(reset: true) }
            }
        )
    }

    private var workshopFilterButton: some View {
        // 工坊页顶栏元素较多，筛选按钮只显示图标
        Button {
            withAnimation(Motion.panel) {
                isWorkshopFilterPresented.toggle()
                isDownloadsPresented = false
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.85))
                .frame(width: 34, height: 34)
                .sceneGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            // 角标：已启用的筛选项数量
            if workshop.filters.activeCount > 0 {
                Text("\(workshop.filters.activeCount)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(Color.accentColor, in: Circle())
                    .offset(x: 3, y: -3)
            }
        }
        .help("筛选：类型、分级、题材、分辨率、排序")
        .anchorPreference(key: PanelTriggerKey.self, value: .bounds) { [.workshopFilter: $0] }
    }

    private var filterButton: some View {
        Button {
            withAnimation(Motion.panel) {
                isFilterPresented.toggle()
                isDownloadsPresented = false
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.85))
                .frame(width: 34, height: 34)
                .sceneGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .help("筛选与排序")
        .anchorPreference(key: PanelTriggerKey.self, value: .bounds) { [.filter: $0] }
    }

    private var folderMenu: some View {
        Menu {
            Button { viewModel.selectedFolderID = nil } label: {
                if viewModel.selectedFolderID == nil {
                    Label("全部收藏", systemImage: "checkmark")
                } else {
                    Text("全部收藏")
                }
            }
            if !viewModel.favoriteFolders.isEmpty { Divider() }
            ForEach(viewModel.favoriteFolders) { folder in
                Button { viewModel.selectedFolderID = folder.id } label: {
                    if viewModel.selectedFolderID == folder.id {
                        Label("\(folder.name) (\(folder.wallpaperIDs.count))", systemImage: "checkmark")
                    } else {
                        Text("\(folder.name) (\(folder.wallpaperIDs.count))")
                    }
                }
            }
            Divider()
            Button {
                newFolderName = ""
                isShowingNewFolderAlert = true
            } label: { Label("新建收藏夹…", systemImage: "plus") }

            if let folder = selectedFolder {
                Divider()
                Button {
                    renameFolderName = folder.name
                    renamingFolder = folder
                    isRenamingFolder = true
                } label: { Label("重命名「\(folder.name)」…", systemImage: "pencil") }
                Button(role: .destructive) {
                    viewModel.deleteFolder(folder)
                } label: { Label("删除「\(folder.name)」", systemImage: "trash") }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                Text(selectedFolder?.name ?? "全部收藏").lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.85))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .sceneGlass(in: Capsule())
    }

    private var selectedFolder: FavoriteFolder? {
        guard let id = viewModel.selectedFolderID else { return nil }
        return viewModel.favoriteFolders.first { $0.id == id }
    }

    // MARK: - Gallery

    @ViewBuilder
    private func gallery(in size: CGSize) -> some View {
        let items = currentItems
        let isLoading = (page == .home && viewModel.isLoading)
            || (page == .workshop && workshop.mode == .online && workshop.isLoading)

        if page == .playlists {
            PlaylistsView(embedded: true, panelWidth: max(360, min(size.width - 64, 1180)), maximumHeight: max(420, min(820, size.height - 118)), onKeyboardHandler: { playlistKeyHandler = $0 })
                .scrollContentBackground(.hidden)
                // 与下载、筛选浮层同一套透明策略：Liquid Glass + 很淡的明暗，背后的壁纸能透出来
                .scenaFrostedPanel()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 78)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
                .onHover { immersive.setHold("playlists", active: $0) }
                // 进入时从下方轻轻升起，离开时淡出
                .transition(.asymmetric(
                    insertion: Motion.reducesMotion ? .opacity : .offset(y: 36).combined(with: .opacity),
                    removal: .opacity
                ))
        } else if items.isEmpty && !isLoading {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isWorkshopGrid {
            WorkshopGridView(
                liveController: liveController,
                items: workshop.items,
                selectedID: selectedItem?.workshop?.id,
                size: size,
                columnCount: $workshopColumns,
                onSelect: { select(GalleryItem(origin: .workshop($0)), isUserInitiated: true) },
                onHover: { reason, active in immersive.setHold(reason, active: active) },
                contextMenu: { contextMenu(for: GalleryItem(origin: .workshop($0))) },
                topInset: topBarInset,
                onFooterVisibleChange: { isWorkshopFooterVisible = $0 }
            )
        } else {
            VStack(alignment: .leading, spacing: 18) {
                Spacer(minLength: 0)

                if let item = displayedInfoItem ?? selectedItem {
                    infoPanel(for: item)
                        .opacity(actionableItem != nil ? 1 : 0.45)
                        .allowsHitTesting(actionableItem != nil)
                        .overlay(alignment: .topTrailing) {
                            if failedBackgroundID == selectedItem?.id, selectedItem != nil {
                                HStack(spacing: 8) {
                                    Label("加载失败", systemImage: "exclamationmark.triangle")
                                    Button("重试") {
                                        failedBackgroundID = nil
                                        backgroundRetryToken += 1
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .font(.caption).foregroundStyle(Color.primary)
                            } else if actionableItem == nil {
                                Label("加载中", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.caption).foregroundStyle(Color.primary.opacity(0.8))
                            }
                        }
                        .animation(Motion.content, value: actionableItem?.id)
                        .opacity(dismissedBackgroundID != nil ? 0 : 1)
                        .offset(y: dismissedBackgroundID != nil && !Motion.reducesMotion ? 8 : 0)
                        .frame(maxWidth: min(size.width * 0.6, 620), alignment: .leading)
                        .padding(.horizontal, 32)
                        .onHover { immersive.setHold("panel", active: $0) }
                }

                ThumbnailStrip(
                    items: items,
                    selectedID: selectedItem?.id,
                    selectionWithoutScrollingID: selectionWithoutScrollingID,
                    centersSelection: centersSelection,
                    removingIDs: removingIDs,
                    thumbHeight: max(72, min(130, size.height * 0.13)),
                    onSelect: { select($0, isUserInitiated: true) },
                    onItemAppear: { item in
                        if page == .home, let wallpaper = item.remote {
                            viewModel.loadMoreIfNeeded(current: wallpaper)
                        }
                        if let workshopItem = item.workshop {
                            workshop.loadMoreIfNeeded(current: workshopItem)
                        }
                    },
                    onActivate: { apply($0) },
                    loadError: page == .home ? viewModel.loadError : nil,
                    onRetry: { viewModel.retryLoading() },
                    downloadState: { $0.workshop.map(workshop.downloadState(of:)) ?? .none },
                    contextMenu: { contextMenu(for: $0) }
                )
                // 重新搜索时旧结果保留并变暗，新结果到了再替换
                .opacity(page == .home && viewModel.isRefreshing ? 0.45 : 1)
                .animation(Motion.content, value: page == .home && viewModel.isRefreshing)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .onHover { immersive.setHold("strip", active: $0) }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            switch page {
            case .home:
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 34, weight: .light))
                Text("未找到符合当前筛选条件的壁纸")
                Button("调整筛选") { isFilterPresented = true }.buttonStyle(.bordered)
            case .favorites:
                Image(systemName: "heart").font(.system(size: 34, weight: .light))
                if collectionSource == .all {
                    Text(workshop.isSyncing ? "正在同步创意工坊订阅…" : "还没有收藏或创意工坊订阅")
                    if !workshop.isLoggedIn {
                        Button("登录 Steam，同步订阅") { openWindow(id: SteamLoginWindow.id) }
                            .buttonStyle(.bordered)
                    }
                } else {
                    Text(viewModel.selectedFolderID == nil ? "还没有收藏，按 L 或点击心形即可收藏" : "该收藏夹中暂无壁纸")
                }
                Button("去发现") {
                    discoverSource = .wallhaven
                    switchTab(.discover)
                }
                .buttonStyle(.bordered)
            case .library:
                Image(systemName: "photo.stack").font(.system(size: 34, weight: .light))
                if librarySource != .all || !libraryQuery.isEmpty {
                    Text("没有符合条件的壁纸")
                    Button("显示全部") {
                        librarySource = .all
                        libraryQuery = ""
                    }
                    .buttonStyle(.bordered)
                } else {
                    Text("资料库还是空的")
                    Text("下载的壁纸、导入的图片和视频、已下载的创意工坊壁纸都会出现在这里")
                        .font(.caption)
                        .foregroundStyle(Color.primary.opacity(0.6))
                    HStack {
                        Button("导入图片或视频") { localViewModel.importFiles() }.buttonStyle(.bordered)
                        Button("添加工坊文件夹") { workshop.addLibraryFolder() }.buttonStyle(.bordered)
                        Button("去发现") { switchTab(.discover) }.buttonStyle(.bordered)
                    }
                }
            case .workshop:
                workshopEmptyState
            case .playlists:
                EmptyView()
            }
        }
        .foregroundStyle(Color.primary.opacity(0.85))
    }

    @ViewBuilder
    private var workshopEmptyState: some View {
        Image(systemName: "square.stack.3d.up").font(.system(size: 34, weight: .light))
        if workshop.mode == .subscribed && !workshop.isLoggedIn {
            Text("登录 Steam 账号，同步创意工坊订阅")
            Text("Windows 上订阅的壁纸会自动下载到 Mac；在 Mac 上下载的壁纸也会同步订阅")
                .font(.caption)
                .foregroundStyle(Color.primary.opacity(0.6))
            Button("登录 Steam") { openWindow(id: SteamLoginWindow.id) }.buttonStyle(.bordered)
        } else if workshop.mode == .subscribed && workshop.isSyncing {
            Text("正在同步订阅…")
        } else if workshop.mode == .subscribed && workshop.subscribedItems.isEmpty {
            Text("这个账号还没有订阅 Wallpaper Engine 壁纸")
            Button("去发现") {
                discoverSource = .workshop
                switchTab(.discover)
            }
            .buttonStyle(.bordered)
        } else {
            Text("没有找到符合条件的壁纸")
            HStack {
                Button("调整筛选") { isWorkshopFilterPresented = true }.buttonStyle(.bordered)
                if !workshop.filters.isDefault {
                    Button("重置筛选") { workshop.resetFilters() }.buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private func infoPanel(for item: GalleryItem) -> some View {
        switch item.origin {
        case .remote(let wallpaper):
            let tags = viewModel.tagsByID[wallpaper.id] ?? []
            InfoPanel(
                eyebrow: "\(page == .favorites ? "FAVORITES" : "FEATURED") · #\(wallpaper.id)",
                title: (tags.first ?? wallpaper.category).capitalized,
                meta: remoteMeta(wallpaper),
                colors: wallpaper.colors,
                tags: Array(tags.dropFirst()),
                onTag: { tag in
                    discoverSource = .wallhaven
                    switchTab(.discover)
                    viewModel.searchTag(tag)
                }
            ) {
                ApplyWallpaperButton(item: item) { viewModel.downloadAndApply(wallpaper) }.id("apply-\(item.id)")
                // 以壁纸 id 作为按钮身份：切换壁纸时直接换新按钮，只有同一张壁纸的状态变化才播放过渡动画
                FavoriteMenuButton(wallpaper: wallpaper)
                    .id("favorite-\(wallpaper.id)")
                RemoteDownloadButton(wallpaper: wallpaper, isInLibrary: downloadedWallhavenIDs.contains(wallpaper.id))
                    .id("download-\(wallpaper.id)")
                AddToPlaylistButton(item: item)
                    .id("playlist-\(item.id)")
                CircleIconButton(systemImage: "safari", help: "在浏览器中打开") { NSWorkspace.shared.open(wallpaper.url) }
            }

        case .local(let local):
            let isLive = liveController.currentURL == local.url
            InfoPanel(
                eyebrow: local.isVideo ? (isLive ? "LIVE · 正在桌面播放" : "LIVE WALLPAPER") : "LOCAL",
                title: local.displayName,
                meta: [
                    FileSizeText.string(Int64(local.fileSize)),
                    local.url.pathExtension.uppercased(),
                ]
            ) {
                ApplyWallpaperButton(item: item) { localViewModel.applyWallpaper(local) }.id("apply-\(item.id)")
                CircleIconButton(systemImage: "folder", help: "在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([local.url])
                }
                AddToPlaylistButton(item: item)
                    .id("playlist-\(item.id)")
                CircleIconButton(systemImage: "trash", tint: .red.opacity(0.9), help: "移到废纸篓") { deleteLocal(local) }
            }

        case .workshop(let workshopItem):
            workshopInfoPanel(workshopItem, item: item)
        }
    }

    /// 沉浸式页面（收藏 · 创意工坊、资料库）里的工坊壁纸信息面板
    @ViewBuilder
    private func workshopInfoPanel(_ workshopItem: WorkshopItem, item: GalleryItem) -> some View {
        let isLive = workshopItem.localFolder.map { liveController.currentURL?.standardizedFileURL == $0.standardizedFileURL } ?? false
        let state = workshop.downloadState(of: workshopItem)
        let isSubscribed = workshop.isSubscribed(workshopItem)
        InfoPanel(
            eyebrow: isLive ? "LIVE · 正在桌面播放" : "WALLPAPER ENGINE · \(workshopItem.type.label)",
            title: workshopItem.title,
            meta: workshopMeta(workshopItem),
            tags: workshopItem.tags,
            onTag: { tag in
                if page == .library {
                    libraryQuery = WorkshopTags.label(for: tag)
                } else {
                    workshop.applyTag(tag)
                }
            },
            tagLabel: WorkshopTags.label(for:)
        ) {
            if !workshopItem.type.isPlayable {
                Text("Windows 程序，macOS 无法运行")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.7))
            } else if state == .queued || state == .downloading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(.primary)
                    Text(state.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.primary)
                    Button("取消") { workshop.cancelDownload(workshopItem) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.primary.opacity(0.7))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .sceneGlass(in: Capsule())
            } else if workshopItem.isDownloaded {
                ApplyWallpaperButton(item: item) { workshop.apply(workshopItem) }.id("apply-\(item.id)")
            } else {
                ApplyWallpaperButton(item: item, title: "下载并应用") { workshop.apply(workshopItem) }.id("apply-\(item.id)")
            }

            if workshop.isLoggedIn, workshopItem.workshopPageURL != nil {
                CircleIconButton(
                    systemImage: isSubscribed ? "heart.fill" : "heart",
                    tint: isSubscribed ? .red : .primary,
                    help: isSubscribed ? "已订阅（点击取消订阅）" : "订阅到 Steam 账号"
                ) { workshop.toggleSubscription(workshopItem) }
                .id("subscribe-\(item.id)")
            }
            // 下载状态：未下载 → 下载中 → 已下载（绿色对勾），在同一个按钮里过渡
            if workshopItem.isDownloaded || workshopItem.type.isPlayable {
                DownloadActionButton(
                    phase: workshopItem.isDownloaded ? .done : (state == .queued || state == .downloading ? .downloading : .idle),
                    help: "仅下载"
                ) { workshop.download(workshopItem) }
                .id("download-\(item.id)")
            }
            // 未下载的也能加：先下载，完成后加入选择的播放列表
            if workshopItem.isDownloaded || workshopItem.type.isPlayable {
                AddToPlaylistButton(item: item)
                    .id("playlist-\(item.id)")
            }
            if let folder = workshopItem.localFolder {
                CircleIconButton(systemImage: "folder", help: "在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
            if workshopItem.workshopPageURL != nil {
                CircleIconButton(systemImage: "arrow.up.forward.app", help: "在 Steam 中打开") { workshop.openInSteam(workshopItem) }
            }
            if workshopItem.isDownloaded {
                if isSubscribed {
                    Menu {
                        Button("移到废纸篓") { deleteFromLibrary(item, unsubscribe: false) }
                        Button("移到废纸篓并取消订阅", role: .destructive) { deleteFromLibrary(item, unsubscribe: true) }
                    } label: {
                        CircleIconLabel(systemImage: "trash", tint: .red.opacity(0.9))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("删除")
                } else {
                    CircleIconButton(systemImage: "trash", tint: .red.opacity(0.9), help: "移到废纸篓") {
                        deleteFromLibrary(item, unsubscribe: false)
                    }
                }
            }
        }
    }

    private func workshopMeta(_ item: WorkshopItem) -> [String] {
        var meta: [String] = []
        if item.fileSize > 0 {
            meta.append(FileSizeText.string(Int64(item.fileSize)))
        }
        if item.subscriptions > 0 { meta.append("\(item.subscriptions) 订阅") }
        if let rating = item.contentRating { meta.append(WorkshopRating(rawValue: rating)?.label ?? rating) }
        meta.append(item.isDownloaded ? "已下载" : "未下载")
        return meta
    }

    private func remoteMeta(_ wallpaper: WallhavenWallpaper) -> [String] {
        var meta = [wallpaper.resolution]
        meta.append("♥ \(wallpaper.favorites)")
        if wallpaper.views > 0 { meta.append("\(wallpaper.views) 次浏览") }
        if wallpaper.fileSize > 0 {
            meta.append(FileSizeText.string(Int64(wallpaper.fileSize)))
        }
        return meta
    }

    @ViewBuilder
    private func contextMenu(for item: GalleryItem) -> some View {
        switch item.origin {
        case .remote(let wallpaper):
            Button("设为壁纸") { viewModel.downloadAndApply(wallpaper) }
            Button(viewModel.isFavorite(wallpaper.id) ? "取消收藏" : "添加收藏") { viewModel.toggleFavorite(wallpaper) }
            Button("下载") { viewModel.downloadImage(wallpaper) }
            AddToPlaylistMenu(item: item)
            Divider()
            Button("在浏览器中打开") { NSWorkspace.shared.open(wallpaper.url) }
        case .local(let local):
            Button("设为壁纸") { localViewModel.applyWallpaper(local) }
            AddToPlaylistMenu(item: item)
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([local.url]) }
            Divider()
            Button("移到废纸篓", role: .destructive) { deleteLocal(local) }
        case .workshop(let workshopItem):
            if workshopItem.type.isPlayable {
                Button(workshopItem.isDownloaded ? "设为壁纸" : "下载并应用") { workshop.apply(workshopItem) }
            }
            if !workshopItem.isDownloaded, workshopItem.type.isPlayable {
                Button("仅下载") { workshop.download(workshopItem) }
            }
            AddToPlaylistMenu(item: item)
            if workshop.isLoggedIn, workshopItem.workshopPageURL != nil {
                Button(workshop.isSubscribed(workshopItem) ? "取消订阅" : "订阅") { workshop.toggleSubscription(workshopItem) }
            }
            if let folder = workshopItem.localFolder {
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
            if workshopItem.workshopPageURL != nil {
                Button("在 Steam 中打开") { workshop.openInSteam(workshopItem) }
            }
            if workshopItem.isDownloaded {
                Divider()
                Button("移到废纸篓", role: .destructive) { workshop.delete(workshopItem) }
                if workshop.isSubscribed(workshopItem) {
                    Button("移到废纸篓并取消订阅", role: .destructive) { workshop.delete(workshopItem, unsubscribe: true) }
                }
            }
        }
    }
}

/// 顶栏搜索默认只占一个按钮的位置；输入结束后保留条件并收起。
private struct CollapsibleSearchField: View {
    let title: String
    @Binding var query: String
    @Binding var isExpanded: Bool
    let onSubmit: () -> Void
    let onClear: () -> Void
    @FocusState private var isFocused: Bool

    private var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if isExpanded { submit() } else { isExpanded = true }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "提交搜索" : title)
            .help(!isExpanded && hasQuery ? "当前搜索：\(query)" : title)
            .overlay(alignment: .topTrailing) {
                if !isExpanded && hasQuery {
                    Circle().fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .padding(5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }

            if isExpanded {
                TextField(title, text: $query,
                          prompt: Text(title).foregroundStyle(Color.primary.opacity(0.55)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary)
                    .focused($isFocused)
                    .frame(width: 170)
                    .padding(.horizontal, 3)
                    .onSubmit { submit() }
                    .onExitCommand { collapse() }
                    .task {
                        // 等输入框挂载后再聚焦，支持按钮和搜索快捷键两种入口。
                        await Task.yield()
                        guard !Task.isCancelled, isExpanded else { return }
                        isFocused = true
                    }
                    .transition(.opacity)

                Button {
                    if !query.isEmpty { onClear() }
                    collapse()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(query.isEmpty ? "取消搜索" : "清除搜索")
                .accessibilityLabel(query.isEmpty ? "取消搜索" : "清除搜索")
                .transition(.opacity)
            }
        }
        .frame(width: isExpanded ? 244 : 34, height: 34, alignment: .leading)
        .clipped()
        .sceneGlass(in: Capsule(), interactive: true)
        .animation(Motion.panel, value: isExpanded)
        .onChange(of: isExpanded) { _, expanded in
            if !expanded { isFocused = false }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { isExpanded = false }
        }
    }

    private func submit() {
        onSubmit()
        collapse()
    }

    private func collapse() {
        isExpanded = false
        isFocused = false
    }
}

private extension View {
    /// 测量视图宽度（用于顶部栏判断是否放得下居中布局）
    func measureWidth(_ width: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width.wrappedValue = $0 }
    }
}

/// 主页签的文字样式：选中时白字 + 半透明底
private struct MainTabLabel: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.6))
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .contentShape(Capsule())
    }
}

/// 顶部栏里会弹出面板的按钮
enum PanelTrigger: Hashable { case filter, workshopFilter, downloads }

/// 各面板触发按钮的位置，面板据此决定从哪里「长」出来
private struct PanelTriggerKey: PreferenceKey {
    static let defaultValue: [PanelTrigger: Anchor<CGRect>] = [:]
    static func reduce(value: inout [PanelTrigger: Anchor<CGRect>], nextValue: () -> [PanelTrigger: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 面板出现：从按钮处的小尺寸弹性伸展，同时由模糊变清晰；减少动态效果时只淡入淡出
private struct PanelGrowModifier: ViewModifier {
    let collapsed: Bool
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .scaleEffect(collapsed ? 0.18 : 1, anchor: anchor)
            .blur(radius: collapsed ? 8 : 0)
            .opacity(collapsed ? 0 : 1)
    }
}

extension AnyTransition {
    static func panelGrow(from anchor: UnitPoint) -> AnyTransition {
        if Motion.reducesMotion { return .opacity }
        return .modifier(
            active: PanelGrowModifier(collapsed: true, anchor: anchor),
            identity: PanelGrowModifier(collapsed: false, anchor: anchor)
        )
    }
}

/// 当前选中页签的位置，供页签行背景里的选中底色定位
private struct SelectedTabAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

/// wallhaven 壁纸的下载按钮：手动下载和后台下载（加入播放列表时自动下载）都显示进度，
/// 只观察下载状态，不让整个主界面跟着刷新
private struct RemoteDownloadButton: View {
    @EnvironmentObject private var viewModel: WallpaperViewModel
    @ObservedObject private var tracker = WallhavenDownloadTracker.shared
    let wallpaper: WallhavenWallpaper
    let isInLibrary: Bool

    private var phase: DownloadActionButton.Phase {
        if isInLibrary || viewModel.downloadedIDs.contains(wallpaper.id) || tracker.downloaded.contains(wallpaper.id) { return .done }
        if viewModel.downloadingIDs.contains(wallpaper.id) || tracker.downloading.contains(wallpaper.id) { return .downloading }
        return .idle
    }

    var body: some View {
        DownloadActionButton(phase: phase) { viewModel.downloadImage(wallpaper) }
    }
}
