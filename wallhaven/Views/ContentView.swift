//
//  ContentView.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import AppKit
import Kingfisher
import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case home = "首页"
    case favorites = "收藏"
    case local = "本地"
    case workshop = "工坊"

    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject private var viewModel: WallpaperViewModel
    @EnvironmentObject private var workshop: WorkshopViewModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var localViewModel = LocalMediaViewModel()
    @StateObject private var immersive = ImmersiveWindowController()
    @ObservedObject private var toastCenter = ToastCenter.shared
    @ObservedObject private var liveController = LiveWallpaperController.shared

    @State private var currentTab: MainTab = .home
    @State private var favoriteSelectionID: String?
    @State private var localSelectionID: String?
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

    private func items(for tab: MainTab) -> [GalleryItem] {
        switch tab {
        case .home:
            return viewModel.wallpapers.map { GalleryItem(origin: .remote($0)) }
        case .favorites:
            let wallpapers = viewModel.selectedFolderID.map(viewModel.wallpapersInFolder) ?? viewModel.favoriteWallpapers
            return wallpapers.map { GalleryItem(origin: .remote($0)) }
        case .local:
            return localViewModel.items.map { GalleryItem(origin: .local($0)) }
        case .workshop:
            return workshop.items.map { GalleryItem(origin: .workshop($0)) }
        }
    }

    private func selectedID(for tab: MainTab) -> String? {
        switch tab {
        case .home: viewModel.selectedWallpaper.map { GalleryItem(origin: .remote($0)).id }
        case .favorites: favoriteSelectionID
        case .local: localSelectionID
        case .workshop: workshopSelectionID
        }
    }

    private var currentItems: [GalleryItem] { items(for: currentTab) }

    private var selectedItem: GalleryItem? {
        guard let id = selectedID(for: currentTab) else { return nil }
        return currentItems.first { $0.id == id }
    }

    private func select(_ item: GalleryItem) {
        selectionWithoutScrollingID = nil
        switch currentTab {
        case .home: viewModel.selectedWallpaper = item.remote
        case .favorites: favoriteSelectionID = item.id
        case .local: localSelectionID = item.id
        case .workshop: workshopSelectionID = item.id
        }
    }

    private func ensureValidSelection() {
        let items = currentItems
        guard !items.isEmpty else { return }
        if selectedItem == nil, let first = items.first {
            select(first)
        }
    }

    private func moveSelection(by offset: Int) {
        let items = currentItems
        guard !items.isEmpty else { return }
        let index = selectedItem.flatMap { item in items.firstIndex(of: item) } ?? 0
        let newIndex = max(0, min(items.count - 1, index + offset))
        let item = items[newIndex]
        select(item)
        if currentTab == .home, let wallpaper = item.remote {
            viewModel.loadMoreIfNeeded(current: wallpaper)
        }
        if let workshopItem = item.workshop {
            workshop.loadMoreIfNeeded(current: workshopItem)
        }
    }

    /// 预加载前后相邻的原图，方便 ←/→ 快速切换
    private func prefetchNeighbors(of item: GalleryItem) {
        let items = currentItems
        guard let index = items.firstIndex(of: item) else { return }
        let sources = [index + 1, index + 2, index - 1]
            .filter { items.indices.contains($0) }
            .compactMap { items[$0].remote == nil ? nil : items[$0].fullSource }
        guard !sources.isEmpty else { return }
        prefetcher?.stop()
        let newPrefetcher = ImagePrefetcher(sources: sources, options: ImageSizing.backgroundOptions)
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
        let wasSelected = localSelectionID == GalleryItem(origin: .local(item)).id
        let deletedIndex = localViewModel.items.firstIndex { $0.id == item.id }
        localViewModel.delete(item: item)
        // 删除失败时保留选中项；删除非选中项也不改变选择和滚动位置。
        guard wasSelected, let deletedIndex,
              !localViewModel.items.contains(where: { $0.id == item.id }) else { return }
        let remaining = localViewModel.items
        if remaining.isEmpty {
            localSelectionID = nil
        } else {
            // 优先选中原位置的下一项，删除最后一项时选中前一项。
            let neighbor = remaining[min(deletedIndex, remaining.count - 1)]
            let neighborID = GalleryItem(origin: .local(neighbor)).id
            selectionWithoutScrollingID = neighborID
            localSelectionID = neighborID
        }
    }

    private func handleKey(_ key: ImmersiveWindowController.Key) -> Bool {
        switch key {
        case .left:
            moveSelection(by: -1)
        case .right:
            moveSelection(by: 1)
        case .up:
            // 工坊网格按行移动
            guard currentTab == .workshop else { return false }
            moveSelection(by: -workshopColumns)
        case .down:
            guard currentTab == .workshop else { return false }
            moveSelection(by: workshopColumns)
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
            guard currentTab == .home else { return false }
            isSearchFocused = true
        case .character("1"): switchTab(.home)
        case .character("2"): switchTab(.favorites)
        case .character("3"): switchTab(.local)
        case .character("4"): switchTab(.workshop)
        default:
            return false
        }
        return true
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
            hasSearch: currentTab == .home || currentTab == .workshop,
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
                switchTab(.local)
                localViewModel.importFiles()
            },
            addWorkshopFolder: {
                switchTab(.workshop)
                workshop.mode = .library
                workshop.addLibraryFolder()
            }
        )
    }

    private func handleMenuNavigation() {
        guard let tab = MainWindow.requestedTab else { return }
        MainWindow.requestedTab = nil
        switchTab(tab)
        if tab == .local { localViewModel.loadMedia() }
        if tab == .workshop { workshop.mode = .library; workshop.refreshLibrary() }
    }

    private func switchTab(_ tab: MainTab) {
        withAnimation(.easeInOut(duration: 0.2)) { currentTab = tab }
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .top) {
                ImmersiveBackground(item: backgroundItem, showsPreviewCard: immersive.isChromeHidden)
                    .frame(width: size.width, height: size.height)

                // 工坊网格界面整体压暗，保证缩略图和文字清晰
                if currentTab == .workshop {
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
                    topBar
                        .opacity(immersive.isChromeHidden ? 0 : 1)
                        .offset(y: immersive.isChromeHidden ? -12 : 0)
                        .allowsHitTesting(!immersive.isChromeHidden)

                    // 提示条不随界面隐藏
                    if let toast = toastCenter.current {
                        ToastView(toast: toast)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .onTapGesture { toastCenter.dismiss() }
                    }
                }
                .padding(.top, 10)

                filterOverlay(maxHeight: size.height - 90)
            }
        }
        .ignoresSafeArea()
        .frame(minWidth: 820, minHeight: 520)
        .background(WindowAccessor { immersive.attach(to: $0) })
        .focusedSceneValue(\.galleryActions, commandActions)
        .onAppear {
            MainWindow.opener = { openWindow(id: MainWindow.id) }
            immersive.keyHandler = handleKey
            handleMenuNavigation()
            viewModel.search(reset: true)
            localViewModel.loadMedia()
            workshop.refreshLibrary()
            // 已登录 Steam 时同步订阅（10 分钟内不重复）
            workshop.syncSubscriptions()
        }
        .onReceive(NotificationCenter.default.publisher(for: MainWindow.navigationNotification)) { _ in
            handleMenuNavigation()
        }
        .onChange(of: currentTab) {
            selectionWithoutScrollingID = nil
            if currentTab == .local { localViewModel.loadMedia() }
            if currentTab == .workshop {
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
        .onChange(of: currentItems.map(\.id), initial: true) {
            ensureValidSelection()
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

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(MainTab.allCases) { tab in
                    Button { switchTab(tab) } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(currentTab == tab ? .white : .white.opacity(0.6))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(currentTab == tab ? .white.opacity(0.2) : .clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(.ultraThinMaterial, in: Capsule())

            Spacer(minLength: 12)

            LiveWallpaperStatus(controller: liveController)
            WorkshopDownloadsButton()

            switch currentTab {
            case .home:
                searchField
                filterButton
            case .favorites:
                folderMenu
            case .local:
                Button { localViewModel.importFiles() } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("导入图片或视频（视频可设为动态壁纸）")
            case .workshop:
                WorkshopModePicker()
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
                if workshop.mode == .library {
                    Button { workshop.addLibraryFolder() } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 34, height: 34)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("添加 Wallpaper Engine 壁纸文件夹或工坊目录")
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
        .padding(.leading, 80) // 红绿灯
        .padding(.trailing, 16)
        .environment(\.colorScheme, .dark)
        .onHover { immersive.setHold("topbar", active: $0) }
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
            TextField(workshop.mode == .online ? "搜索工坊或粘贴链接" : "搜索已下载", text: $workshop.query)
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
        let isLoading = (currentTab == .home && viewModel.isLoading)
            || (currentTab == .workshop && workshop.mode == .online && workshop.isLoading)

        if items.isEmpty && !isLoading {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if currentTab == .workshop {
            WorkshopGridView(
                liveController: liveController,
                items: workshop.items,
                selectedID: selectedItem?.workshop?.id,
                size: size,
                columnCount: $workshopColumns,
                onSelect: { select(GalleryItem(origin: .workshop($0))) },
                onHover: { reason, active in immersive.setHold(reason, active: active) },
                contextMenu: { contextMenu(for: GalleryItem(origin: .workshop($0))) }
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
                    onSelect: { select($0) },
                    onItemAppear: { item in
                        if currentTab == .home, let wallpaper = item.remote {
                            viewModel.loadMoreIfNeeded(current: wallpaper)
                        }
                        if let workshopItem = item.workshop {
                            workshop.loadMoreIfNeeded(current: workshopItem)
                        }
                    },
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
            switch currentTab {
            case .home:
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 34, weight: .light))
                Text("未找到符合当前筛选条件的壁纸")
                Button("调整筛选") { isFilterPresented = true }.buttonStyle(.bordered)
            case .favorites:
                Image(systemName: "heart").font(.system(size: 34, weight: .light))
                Text(viewModel.selectedFolderID == nil ? "还没有收藏，按 L 或点击心形即可收藏" : "该收藏夹中暂无壁纸")
                Button("去浏览") { switchTab(.home) }.buttonStyle(.bordered)
            case .local:
                Image(systemName: "photo.stack").font(.system(size: 34, weight: .light))
                Text("本地还没有壁纸")
                Text("下载的壁纸会出现在这里，也可以导入视频作为动态壁纸")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                Button("导入图片或视频") { localViewModel.importFiles() }.buttonStyle(.bordered)
            case .workshop:
                workshopEmptyState
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
            Button("在线浏览") { workshop.mode = .online }.buttonStyle(.bordered)
        } else if workshop.mode == .library && workshop.libraryItems.isEmpty {
            Text("还没有 Wallpaper Engine 壁纸")
            Text("添加从 Steam 下载的壁纸文件夹，或切换到「在线」浏览创意工坊")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
            HStack {
                Button("添加文件夹") { workshop.addLibraryFolder() }.buttonStyle(.bordered)
                Button("在线浏览") { workshop.mode = .online }.buttonStyle(.bordered)
            }
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
                eyebrow: "\(currentTab == .favorites ? "FAVORITES" : "FEATURED") · #\(wallpaper.id)",
                title: (tags.first ?? wallpaper.category).capitalized,
                meta: remoteMeta(wallpaper),
                colors: wallpaper.colors,
                tags: Array(tags.dropFirst()),
                onTag: { tag in
                    switchTab(.home)
                    viewModel.searchTag(tag)
                }
            ) {
                PrimaryActionButton(title: "设为壁纸") { viewModel.downloadAndApply(wallpaper) }
                FavoriteMenuButton(wallpaper: wallpaper)
                CircleIconButton(systemImage: "arrow.down", help: "下载 (D)") { viewModel.downloadImage(wallpaper) }
                AddToPlaylistButton(item: item)
                CircleIconButton(systemImage: "safari", help: "在浏览器中打开") { NSWorkspace.shared.open(wallpaper.url) }
            }

        case .local(let local):
            let isLive = liveController.currentURL == local.url
            InfoPanel(
                eyebrow: local.isVideo ? (isLive ? "LIVE · 正在桌面播放" : "LIVE WALLPAPER") : "LOCAL",
                title: local.displayName,
                meta: [
                    ByteCountFormatter.string(fromByteCount: Int64(local.fileSize), countStyle: .file),
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

        case .workshop:
            // 工坊页使用网格 + 右侧详情栏（WorkshopGridView）
            EmptyView()
        }
    }

    private func remoteMeta(_ wallpaper: WallhavenWallpaper) -> [String] {
        var meta = [wallpaper.resolution]
        meta.append("♥ \(wallpaper.favorites)")
        if wallpaper.views > 0 { meta.append("\(wallpaper.views) 次浏览") }
        if wallpaper.fileSize > 0 {
            meta.append(ByteCountFormatter.string(fromByteCount: Int64(wallpaper.fileSize), countStyle: .file))
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
