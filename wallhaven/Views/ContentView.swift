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

/// 页签 + 来源决定实际显示的画廊页面
private enum GalleryPage: Equatable {
    case home, favorites, workshop, library, playlists
}

struct ContentView: View {
    @EnvironmentObject private var viewModel: WallpaperViewModel
    @EnvironmentObject private var workshop: WorkshopViewModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var localViewModel = LocalMediaViewModel()
    @StateObject private var immersive = ImmersiveWindowController()
    @State private var galleryTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @ObservedObject private var toastCenter = ToastCenter.shared
    @ObservedObject private var liveController = LiveWallpaperController.shared

    @State private var currentTab: MainTab = .discover
    @AppStorage("ui.discoverSource") private var discoverSource: ContentSource = .wallhaven
    @AppStorage("ui.collectionSource") private var collectionSource: ContentSource = .wallhaven
    @State private var favoriteSelectionID: String?
    @State private var localSelectionID: String?
    @State private var librarySource: LibrarySource = .all
    @State private var libraryQuery = ""
    @State private var topBarTabsWidth: CGFloat = 0
    @State private var topBarTrailingWidth: CGFloat = 0
    /// 只有主动选择/导航才要求缩略图滚动；删除后的邻项选择保留当前视口。
    @State private var selectionWithoutScrollingID: String?
    @State private var workshopSelectionID: String?
    @State private var isWorkshopFilterPresented = false
    @State private var workshopColumns = 4
    /// 背景只在有新选中项时更新：搜索重置、列表清空期间保持上一张，不会跳到随机图
    @State private var backgroundItem: GalleryItem?
    @State private var prefetcher: ImagePrefetcher?
    @State private var isFilterPresented = false
    @FocusState private var isSearchFocused: Bool

    @State private var isShowingNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var isRenamingFolder = false
    @State private var renamingFolder: FavoriteFolder?
    @State private var renameFolderName = ""

    // MARK: - Data

    private var page: GalleryPage {
        switch currentTab {
        case .discover: discoverSource == .wallhaven ? .home : .workshop
        case .collections: collectionSource == .wallhaven ? .favorites : .workshop
        case .library: .library
        case .playlists: .playlists
        }
    }

    /// 工坊网格的数据随页签切换：发现 = 在线，收藏 = 已订阅
    private func syncWorkshopMode() {
        guard page == .workshop else { return }
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
            let wallpapers = viewModel.selectedFolderID.map(viewModel.wallpapersInFolder) ?? viewModel.favoriteWallpapers
            // 收藏按加入顺序保存，最新收藏的排在最前
            return wallpapers.reversed().map { GalleryItem(origin: .remote($0)) }
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

    private func select(_ item: GalleryItem, isUserInitiated: Bool = false) {
        if isUserInitiated { immersive.userDidSelectThumbnail() }
        selectionWithoutScrollingID = nil
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

    /// 删除（移到废纸篓）。删除选中项后选中原位置的邻项由 ensureValidSelection 统一处理
    private func deleteFromLibrary(_ item: GalleryItem, unsubscribe: Bool) {
        switch item.origin {
        case .local(let local): localViewModel.delete(item: local)
        case .workshop(let workshopItem): workshop.delete(workshopItem, unsubscribe: unsubscribe)
        case .remote: return
        }
    }

    private func handleKey(_ key: ImmersiveWindowController.Key) -> Bool {
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
            guard let item = selectedItem else { return false }
            apply(item)
        case .character("d"):
            guard let wallpaper = selectedItem?.remote else { return false }
            viewModel.downloadImage(wallpaper)
        case .character("l"):
            guard let wallpaper = selectedItem?.remote else { return false }
            viewModel.toggleFavorite(wallpaper)
        case .character("/"):
            guard hasSearch else { return false }
            isSearchFocused = true
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
        let item = selectedItem
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
            apply: { if let item = selectedItem { apply(item) } },
            download: {
                switch selectedItem?.origin {
                case .remote(let wallpaper): viewModel.downloadImage(wallpaper)
                case .workshop(let workshopItem): workshop.download(workshopItem)
                default: break
                }
            },
            toggleFavorite: { if let wallpaper = selectedItem?.remote { viewModel.toggleFavorite(wallpaper) } },
            move: { moveSelection(by: $0) },
            toggleChrome: { immersive.toggleChrome() },
            switchTab: { switchTab($0) },
            focusSearch: {
                immersive.showChrome()
                isSearchFocused = true
            },
            openInBrowser: {
                if let url = selectedItem?.remote?.url ?? selectedItem?.workshop?.workshopPageURL {
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
        guard let tab = MainWindow.requestedTab else { return }
        MainWindow.requestedTab = nil
        switchTab(tab)
        if tab == .library {
            localViewModel.loadMedia()
            workshop.refreshLibrary()
        }
    }

    private func switchTab(_ tab: MainTab) {
        withAnimation(.easeInOut(duration: 0.2)) { currentTab = tab }
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .top) {
                // 未下载的工坊条目：网格页的预览在详情栏里；沉浸式页面平时把卡片放在右上，隐藏界面后居中
                ImmersiveBackground(
                    item: backgroundItem,
                    showsPreviewCard: isWorkshopGrid ? immersive.isChromeHidden : true,
                    centersPreviewCard: isWorkshopGrid || immersive.isChromeHidden
                )
                    .frame(width: size.width, height: size.height)
                    // 沉浸式页面双击图片：隐藏 / 显示界面，只看图片细节（同空格键）
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard !isWorkshopGrid, page != .playlists else { return }
                        immersive.toggleChrome()
                    }

                // 网格类页面整体压暗，保证缩略图和文字清晰
                if isWorkshopGrid || page == .playlists {
                    Color.black.opacity(immersive.isChromeHidden ? 0 : 0.35)
                        .allowsHitTesting(false)
                }

                scrims(height: size.height)
                    .opacity(immersive.isChromeHidden ? 0 : 1)
                    .allowsHitTesting(false)

                gallery(in: size)
                    .frame(width: size.width, height: size.height)
                    .opacity(immersive.isChromeHidden ? 0 : 1)
                    .offset(y: immersive.isChromeHidden ? 24 : 0)
                    .allowsHitTesting(!immersive.isChromeHidden)

                VStack(spacing: 12) {
                    topBar(width: size.width)
                        // 兜底：即使放不下也只裁掉边缘，不会撑宽父视图、把整个界面推歪露出白边
                        .frame(width: size.width)
                        .clipped()
                        .opacity(immersive.isChromeHidden ? 0 : 1)
                        .offset(y: immersive.isChromeHidden ? -12 : 0)
                        .allowsHitTesting(!immersive.isChromeHidden)
                }
                .padding(.top, 10)

                // 提示条放在右上角顶部栏下方，不随界面隐藏
                VStack {
                    if let toast = toastCenter.current {
                        ToastView(toast: toast)
                            .frame(maxWidth: 380, alignment: .trailing)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                            .onTapGesture { toastCenter.dismiss() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, topBarInset + 8)
                .padding(.trailing, 16)

                filterOverlay(maxHeight: size.height - 90)
            }
        }
        .ignoresSafeArea()
        // 最小尺寸要放得下顶部栏最宽的情况（页签 + 来源切换 + 搜索、筛选等工具），否则内容会把整个界面挤歪
        .frame(minWidth: 1120, minHeight: 640)
        .background(WindowAccessor { immersive.attach(to: $0) })
        .focusedSceneValue(\.galleryActions, commandActions)
        .onAppear {
            MainWindow.opener = { openWindow(id: MainWindow.id) }
            immersive.keyHandler = handleKey
            handleMenuNavigation()
            syncWorkshopMode()
            viewModel.search(reset: true)
            localViewModel.loadMedia()
            workshop.refreshLibrary()
            // 已登录 Steam 时同步订阅（10 分钟内不重复）
            workshop.syncSubscriptions()
        }
        .onReceive(galleryTimer) { _ in
            guard !isWorkshopGrid, page != .playlists, immersive.canAdvanceGallery,
                  currentItems.count > 1 else { return }
            let index = selectedItem.flatMap { currentItems.firstIndex(of: $0) } ?? -1
            select(currentItems[(index + 1) % currentItems.count])
        }
        .onReceive(NotificationCenter.default.publisher(for: MainWindow.navigationNotification)) { _ in
            handleMenuNavigation()
        }
        .onChange(of: page) {
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
            closeFilterPanels()
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
        }
        .onChange(of: viewModel.sortOrder) { viewModel.search(reset: true) }
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message else { return }
            toastCenter.show(message, style: .error)
            viewModel.errorMessage = nil
        }
        .onChange(of: isSearchFocused) { _, focused in immersive.setHold("search", active: focused) }
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

    /// 筛选面板浮层：点击面板外部关闭
    @ViewBuilder
    private func filterOverlay(maxHeight: CGFloat) -> some View {
        if isFilterPresented || isWorkshopFilterPresented {
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.001)
                    .onTapGesture { closeFilterPanels() }
                Group {
                    if isWorkshopFilterPresented {
                        WorkshopFilterPanel(maxHeight: maxHeight)
                    } else {
                        FilterPanel()
                    }
                }
                .padding(.top, 58)
                .padding(.trailing, 16)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            }
        }
    }

    private func closeFilterPanels() {
        withAnimation(.easeOut(duration: 0.18)) {
            isFilterPresented = false
            isWorkshopFilterPresented = false
        }
    }

    /// 上下渐变暗角，保证文字在任何壁纸上都可读
    private func scrims(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 110)
            Spacer(minLength: 0)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.35), location: 0.45),
                    .init(color: .black.opacity(0.75), location: 1),
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
        .animation(.easeInOut(duration: 0.2), value: canCenter)
        .environment(\.colorScheme, .dark)
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
                                Text("·").foregroundStyle(.white.opacity(0.45))
                                Text(source).foregroundStyle(.white.opacity(0.85))
                            }
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .modifier(MainTabLabel(isSelected: true))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("切换来源")
                } else {
                    Button { switchTab(tab) } label: {
                        Text(tab.rawValue).modifier(MainTabLabel(isSelected: currentTab == tab))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .measureWidth($topBarTabsWidth)
        .animation(.easeInOut(duration: 0.2), value: currentTab)
    }

    /// 页签上显示的当前来源；nil 表示这个页签没有来源可选
    private func sourceTitle(for tab: MainTab) -> String? {
        switch tab {
        case .discover: discoverSource.rawValue
        case .collections: collectionSource.rawValue
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
                ForEach(ContentSource.allCases) { Text($0.rawValue).tag($0) }
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
            WorkshopDownloadsButton()

            switch page {
            case .home:
                searchField
                filterButton
            case .favorites:
                folderMenu
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
                            .foregroundStyle(.white.opacity(0.85))
                            .rotationEffect(.degrees(workshop.isSyncing ? 360 : 0))
                            .animation(workshop.isSyncing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: workshop.isSyncing)
                            .frame(width: 34, height: 34)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(workshop.isSyncing)
                    .help("与 Steam 同步订阅")
                }
            }

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help("设置")
        }
    }

    private var librarySearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            TextField("搜索资料库", text: $libraryQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .focused($isSearchFocused)
                .frame(width: isSearchFocused ? 170 : 120)
                .onSubmit { isSearchFocused = false }
            if !libraryQuery.isEmpty {
                Button { libraryQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSearchFocused)
    }

    private var libraryAddMenu: some View {
        Menu {
            Button("导入图片或视频…") { localViewModel.importFiles() }
            Button("添加 Wallpaper Engine 文件夹…") { workshop.addLibraryFolder() }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("添加到资料库")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            TextField("搜索壁纸", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .focused($isSearchFocused)
                .frame(width: isSearchFocused ? 180 : 120)
                .onSubmit {
                    viewModel.search(reset: true)
                    isSearchFocused = false
                }
            if !viewModel.query.isEmpty {
                Button {
                    viewModel.query = ""
                    viewModel.search(reset: true)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSearchFocused)
    }

    private var workshopSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            TextField(workshop.mode == .online ? "搜索工坊或粘贴链接" : "搜索订阅", text: $workshop.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .focused($isSearchFocused)
                .frame(width: isSearchFocused ? 170 : 120)
                .onSubmit {
                    // 已下载模式是实时过滤，无需提交
                    if workshop.mode == .online { workshop.search(reset: true) }
                    isSearchFocused = false
                }
            if !workshop.query.isEmpty {
                Button {
                    workshop.query = ""
                    if workshop.mode == .online { workshop.search(reset: true) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSearchFocused)
    }

    private var workshopFilterButton: some View {
        // 工坊页顶栏元素较多，筛选按钮只显示图标
        Button {
            withAnimation(.easeOut(duration: 0.18)) { isWorkshopFilterPresented.toggle() }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            // 角标：已启用的筛选项数量
            if workshop.filters.activeCount > 0 {
                Text("\(workshop.filters.activeCount)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(.white, in: Circle())
                    .offset(x: 3, y: -3)
            }
        }
        .help("筛选：类型、分级、题材、分辨率、排序")
    }

    private var filterButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { isFilterPresented.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                Text(viewModel.sortOrder.label).lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("筛选与排序")
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
            .foregroundStyle(.white.opacity(0.85))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
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
            PlaylistsView(embedded: true, panelWidth: max(360, min(size.width - 64, 1180)), maximumHeight: max(420, min(820, size.height - 118)))
                .scrollContentBackground(.hidden)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.5))
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 78)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
                .onHover { immersive.setHold("playlists", active: $0) }
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
                topInset: topBarInset
            )
        } else {
            VStack(alignment: .leading, spacing: 18) {
                Spacer(minLength: 0)

                if let item = selectedItem {
                    infoPanel(for: item)
                        .frame(maxWidth: min(size.width * 0.6, 620), alignment: .leading)
                        .padding(.horizontal, 32)
                        .onHover { immersive.setHold("panel", active: $0) }
                }

                ThumbnailStrip(
                    items: items,
                    selectedID: selectedItem?.id,
                    selectionWithoutScrollingID: selectionWithoutScrollingID,
                    isLoading: isLoading,
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
                Text(viewModel.selectedFolderID == nil ? "还没有收藏，按 L 或点击心形即可收藏" : "该收藏夹中暂无壁纸")
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
                        .foregroundStyle(.white.opacity(0.6))
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
        .foregroundStyle(.white.opacity(0.85))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var workshopEmptyState: some View {
        Image(systemName: "square.stack.3d.up").font(.system(size: 34, weight: .light))
        if workshop.mode == .subscribed && !workshop.isLoggedIn {
            Text("登录 Steam 账号，同步创意工坊订阅")
            Text("Windows 上订阅的壁纸会自动下载到 Mac；在 Mac 上下载的壁纸也会同步订阅")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
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
                PrimaryActionButton(title: "设为壁纸") { viewModel.downloadAndApply(wallpaper) }
                FavoriteMenuButton(wallpaper: wallpaper)
                if downloadedWallhavenIDs.contains(wallpaper.id) {
                    DownloadedIndicator()
                } else {
                    CircleIconButton(systemImage: "arrow.down", help: "下载 (D)") { viewModel.downloadImage(wallpaper) }
                }
                AddToPlaylistButton(item: item)
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
                PrimaryActionButton(title: local.isVideo ? "设为动态壁纸" : "设为壁纸") { localViewModel.applyWallpaper(local) }
                CircleIconButton(systemImage: "folder", help: "在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([local.url])
                }
                AddToPlaylistButton(item: item)
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
                    .foregroundStyle(.white.opacity(0.7))
            } else if state == .queued || state == .downloading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text(state.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    Button("取消") { workshop.cancelDownload(workshopItem) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            } else if workshopItem.isDownloaded {
                PrimaryActionButton(title: "设为动态壁纸") { workshop.apply(workshopItem) }
            } else {
                PrimaryActionButton(title: "下载并应用", systemImage: "arrow.down") { workshop.apply(workshopItem) }
            }

            if workshop.isLoggedIn, workshopItem.workshopPageURL != nil {
                CircleIconButton(
                    systemImage: isSubscribed ? "heart.fill" : "heart",
                    tint: isSubscribed ? .red : .white,
                    help: isSubscribed ? "已订阅（点击取消订阅）" : "订阅到 Steam 账号"
                ) { workshop.toggleSubscription(workshopItem) }
            }
            // 未下载的也能加：先下载，完成后加入选择的播放列表
            // 下载状态：已下载是绿色对勾，未下载可以只下载不应用
            if workshopItem.isDownloaded {
                DownloadedIndicator()
            } else if workshopItem.type.isPlayable, state != .queued, state != .downloading {
                CircleIconButton(systemImage: "arrow.down", help: "仅下载") { workshop.download(workshopItem) }
            }
            if workshopItem.isDownloaded || workshopItem.type.isPlayable {
                AddToPlaylistButton(item: item)
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
            Button(local.isVideo ? "设为动态壁纸" : "设为壁纸") { localViewModel.applyWallpaper(local) }
            AddToPlaylistMenu(item: item)
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([local.url]) }
            Divider()
            Button("移到废纸篓", role: .destructive) { deleteLocal(local) }
        case .workshop(let workshopItem):
            if workshopItem.type.isPlayable {
                Button(workshopItem.isDownloaded ? "设为动态壁纸" : "下载并应用") { workshop.apply(workshopItem) }
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
            .foregroundStyle(isSelected ? .white : .white.opacity(0.6))
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Capsule().fill(isSelected ? .white.opacity(0.2) : .clear))
            .contentShape(Capsule())
    }
}
