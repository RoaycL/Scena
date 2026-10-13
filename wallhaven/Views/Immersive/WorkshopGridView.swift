//
//  WorkshopGridView.swift
//  wallhaven
//
//  创意工坊页的「网格 + 右侧详情栏」布局（参考 Wallpaper Engine 官方客户端）。
//  工坊预览图都是小尺寸方图，网格一屏能看到更多，详情和操作放在右侧栏。
//

import Kingfisher
import SwiftUI

struct WorkshopGridView<MenuItems: View>: View {
    @EnvironmentObject private var workshop: WorkshopViewModel
    @ObservedObject var liveController: LiveWallpaperController

    let items: [WorkshopItem]
    let selectedID: String?
    let size: CGSize
    /// 当前列数，供 ↑/↓ 键按行移动
    @Binding var columnCount: Int
    let onSelect: (WorkshopItem) -> Void
    let onHover: (String, Bool) -> Void
    @ViewBuilder let contextMenu: (WorkshopItem) -> MenuItems

    private let spacing: CGFloat = 10
    private let panelWidth: CGFloat = 300
    private let minTileWidth: CGFloat = 140
    private let edgePadding: CGFloat = 16

    private var columns: Int {
        let gridWidth = size.width - panelWidth - edgePadding * 3
        return max(2, Int((gridWidth + spacing) / (minTileWidth + spacing)))
    }

    var body: some View {
        let selected = items.first { $0.id == selectedID }

        HStack(alignment: .top, spacing: edgePadding) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
                        spacing: spacing
                    ) {
                        ForEach(items) { item in
                            WorkshopTile(
                                item: item,
                                isSelected: item.id == selectedID,
                                downloadState: workshop.downloadState(of: item),
                                isLive: isLive(item)
                            )
                            .id(item.id)
                            .onTapGesture { onSelect(item) }
                            .contextMenu { contextMenu(item) }
                            .onAppear { workshop.loadMoreIfNeeded(current: item) }
                        }
                    }
                    .padding(.vertical, 4)

                    if workshop.mode == .online && workshop.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                            .padding(.vertical, 16)
                    }
                }
                .onChange(of: selectedID) { _, id in
                    guard let id else { return }
                    // anchor 为 nil：只在选中项不可见时滚动最小距离
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id) }
                }
            }
            .frame(maxWidth: .infinity)
            .onHover { onHover("grid", $0) }

            Group {
                if let selected {
                    WorkshopDetailPanel(item: selected, isLive: isLive(selected), maxHeight: size.height - 74 - edgePadding)
                } else {
                    Color.clear
                }
            }
            .frame(width: panelWidth)
            .onHover { onHover("panel", $0) }
        }
        .padding(.top, 58)
        .padding(.horizontal, edgePadding)
        .padding(.bottom, edgePadding)
        .onAppear { columnCount = columns }
        .onChange(of: columns) { _, newValue in columnCount = newValue }
    }

    private func isLive(_ item: WorkshopItem) -> Bool {
        guard let folder = item.localFolder, let live = liveController.currentURL else { return false }
        return live.standardizedFileURL == folder.standardizedFileURL
    }
}

// MARK: - Tile

private struct WorkshopTile: View {
    let item: WorkshopItem
    let isSelected: Bool
    let downloadState: DownloadState
    let isLive: Bool

    @State private var isHovered = false

    var body: some View {
        let gallery = GalleryItem(origin: .workshop(item))
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                KFImage(source: gallery.thumbnailSource)
                    .setProcessor(gallery.thumbnailProcessor)
                    .scaleFactor(ImageSizing.scale)
                    .cancelOnDisappear(true)
                    .placeholder { Color.white.opacity(0.06) }
                    .fade(duration: 0.2)
                    .resizable()
                    .scaledToFill()
            }
            .overlay {
                // 悬停时播放 GIF 预览
                if isHovered, let url = item.previewURL, url.pathExtension.lowercased() == "gif" || !url.isFileURL {
                    AnimatedPreviewImage(url: url, scalesToFill: true)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(item.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                    )
            }
            .overlay {
                if downloadState != .none && downloadState != .completed {
                    DownloadingOverlay(state: downloadState)
                }
            }
            .overlay(alignment: .topLeading) {
                typeBadge.padding(6)
            }
            .overlay(alignment: .topTrailing) {
                statusBadge.padding(6)
            }
            .clipShape(shape)
            .overlay(
                shape.stroke(isSelected ? Color.white : Color.white.opacity(isHovered ? 0.35 : 0.12), lineWidth: isSelected ? 2.5 : 1)
            )
            .brightness(isHovered && !isSelected ? 0.05 : 0)
            .contentShape(shape)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .animation(.easeOut(duration: 0.15), value: isSelected)
    }

    private var typeBadge: some View {
        let symbol: String? = switch item.type {
        case .scene: "cube"
        case .video: "film"
        case .web: "globe"
        default: nil
        }
        return Group {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 20, height: 20)
                    .background(.black.opacity(0.45), in: Circle())
                    .help(item.type.label)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isLive {
            Text("LIVE")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.green, in: Capsule())
        } else if item.isDownloaded {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.green.opacity(0.85), in: Circle())
                .help("已下载")
        }
    }
}

// MARK: - Detail panel

private struct WorkshopDetailPanel: View {
    @EnvironmentObject private var workshop: WorkshopViewModel
    let item: WorkshopItem
    let isLive: Bool
    let maxHeight: CGFloat

    var body: some View {
        let gallery = GalleryItem(origin: .workshop(item))
        let isDownloading = workshop.downloading.contains(item.id)

        GlassPanel(width: 300, maxHeight: maxHeight) {
            // 预览：静态图立即显示，GIF 加载后在上层播放
            ZStack {
                KFImage(source: gallery.thumbnailSource)
                    .setProcessor(gallery.thumbnailProcessor)
                    .placeholder { Color.white.opacity(0.06) }
                    .resizable()
                    .scaledToFill()
                if let url = item.previewURL {
                    AnimatedPreviewImage(url: url)
                        .id(url)
                }
                let state = workshop.downloadState(of: item)
                if state != .none {
                    DownloadingOverlay(state: state, large: true)
                }
            }
            .frame(width: 264, height: 264)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(isLive ? "LIVE · 正在桌面播放" : "WALLPAPER ENGINE · \(item.type.label)")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(isLive ? .green : .white.opacity(0.55))
                Text(item.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            FlowLayout(spacing: 6) {
                if let rating = item.contentRating.flatMap(WorkshopRating.init(rawValue:)) {
                    metaChip(rating.label, color: ratingColor(rating))
                }
                if item.fileSize > 0 {
                    metaChip(ByteCountFormatter.string(fromByteCount: Int64(item.fileSize), countStyle: .file))
                }
                if item.subscriptions > 0 {
                    metaChip("\(item.subscriptions.formatted()) 订阅")
                }
                metaChip(item.isDownloaded ? "已下载" : "未下载", color: item.isDownloaded ? .green : nil)
            }

            if !item.tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(item.tags, id: \.self) { tag in
                        GlassChip(title: "#\(WorkshopTags.label(for: tag))", isOn: false) {
                            workshop.applyTag(tag)
                        }
                        .help(WorkshopTags.isGenre(tag) ? "按此题材筛选" : "搜索此标签")
                    }
                }
            }

            actions(isDownloading: isDownloading)
        }
    }

    @ViewBuilder
    private func actions(isDownloading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !item.type.isPlayable {
                Text("Windows 程序，macOS 无法运行")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            } else if [.paused, .failed, .cancelled].contains(workshop.downloadState(of: item)) {
                HStack {
                    Text(workshop.downloadState(of: item).label)
                    Spacer()
                    Button(workshop.downloadState(of: item) == .failed ? "重试" : "恢复") {
                        workshop.resumeDownload(item.id)
                    }
                    if workshop.downloadState(of: item) != .cancelled {
                        Button("停止") { workshop.cancelDownload(item) }
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.white)
            } else if isDownloading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text(workshop.downloadState(of: item).label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("暂停") { workshop.pauseDownload(item.id) }
                        .buttonStyle(.plain)
                    Button("停止") { workshop.cancelDownload(item) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.white.opacity(0.1), in: Capsule())
            } else {
                Button { workshop.apply(item) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.isDownloaded ? "play.fill" : "arrow.down")
                        Text(item.isDownloaded ? "设为动态壁纸" : "下载并应用")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("回车")
            }

            if workshop.isLoggedIn, item.workshopPageURL != nil {
                let subscribed = workshop.isSubscribed(item)
                Button { workshop.toggleSubscription(item) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: subscribed ? "checkmark.circle.fill" : "plus.circle")
                        Text(subscribed ? "已订阅" : "订阅")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(subscribed ? .green : .white.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(.white.opacity(0.1), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help(subscribed ? "已在 Steam 订阅，Windows 上的 Wallpaper Engine 会同步；点击取消订阅" : "订阅到 Steam 账号，Windows 上的 Wallpaper Engine 会自动下载")
            }

            HStack(spacing: 8) {
                if !item.isDownloaded, item.type.isPlayable, !isDownloading {
                    CircleIconButton(systemImage: "arrow.down.to.line", help: "仅下载") { workshop.download(item) }
                }
                if item.isDownloaded {
                    AddToPlaylistButton(item: GalleryItem(origin: .workshop(item)))
                }
                if item.workshopPageURL != nil {
                    CircleIconButton(systemImage: "arrow.up.forward.app", help: "在 Steam 中打开（可订阅）") { workshop.openInSteam(item) }
                }
                if let folder = item.localFolder {
                    CircleIconButton(systemImage: "folder", help: "在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                    if workshop.isSubscribed(item) {
                        Menu {
                            Button("移到废纸篓") { workshop.delete(item) }
                            Button("移到废纸篓并取消订阅", role: .destructive) { workshop.delete(item, unsubscribe: true) }
                        } label: {
                            CircleIconLabel(systemImage: "trash", tint: .red.opacity(0.9))
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("删除")
                    } else {
                        CircleIconButton(systemImage: "trash", tint: .red.opacity(0.9), help: "移到废纸篓") { workshop.delete(item) }
                    }
                }
            }
        }
    }

    private func metaChip(_ text: String, color: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color ?? .white.opacity(0.75))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((color ?? .white).opacity(0.12), in: Capsule())
    }

    private func ratingColor(_ rating: WorkshopRating) -> Color {
        switch rating {
        case .everyone: .green
        case .questionable: .orange
        case .mature: .red
        }
    }
}

/// 下载中 / 排队中的遮罩：中间显示旋转的刷新图标
struct DownloadingOverlay: View {
    let state: DownloadState
    var large = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
            VStack(spacing: large ? 10 : 6) {
                Group {
                    if state == .downloading {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .symbolEffect(.rotate, options: .repeat(.continuous))
                    } else {
                        Image(systemName: state == .paused ? "pause.circle" : state == .failed ? "exclamationmark.circle" : state == .cancelled ? "stop.circle" : "clock")
                    }
                }
                .font(.system(size: large ? 34 : 22, weight: .semibold))
                .foregroundStyle(.white)

                Text(state.label)
                    .font(.system(size: large ? 13 : 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}
