//
//  ContentView.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import AppKit
import SwiftUI
import Kingfisher

enum MainTab: String, CaseIterable, Identifiable {
    case home = "首页"
    case favorites = "收藏"
    case local = "本地"
    
    var id: String { rawValue }
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
