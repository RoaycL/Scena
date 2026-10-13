//
//  LibraryGridView.swift
//  wallhaven
//
//  「资料库」：硬盘上所有可以直接设为壁纸的内容放在一起
//  （wallhaven 下载、导入的图片和视频、已下载的创意工坊壁纸），网格 + 右侧详情栏。
//

import Kingfisher
import SwiftUI

/// 资料库的类型筛选
enum LibraryKind: String, CaseIterable, Identifiable {
    case all = "全部"
    case image = "图片"
    case video = "视频"
    case workshop = "工坊"

    var id: String { rawValue }

    func matches(_ item: GalleryItem) -> Bool {
        switch self {
        case .all: true
        case .image: item.local.map { !$0.isVideo } ?? false
        case .video: item.local?.isVideo ?? false
        case .workshop: item.workshop != nil
        }
    }
}

extension GalleryItem {
    var libraryTitle: String {
        switch origin {
        case .remote(let wallpaper): "wallhaven #\(wallpaper.id)"
        case .local(let item): item.displayName
        case .workshop(let item): item.title
        }
    }

    var libraryKindLabel: String {
        switch origin {
        case .remote: "wallhaven"
        case .local(let item): item.isVideo ? "视频" : "图片"
        case .workshop(let item): "工坊 · \(item.type.label)"
        }
    }

    var librarySymbol: String {
        switch origin {
        case .remote: "photo"
        case .local(let item): item.isVideo ? "film" : "photo"
        case .workshop(let item):
            switch item.type {
            case .video: "film"
            case .web: "globe"
            default: "cube"
            }
        }
    }

    /// 本地文件夹或文件（用于在 Finder 中显示）
    var libraryFileURL: URL? {
        switch origin {
        case .remote: nil
        case .local(let item): item.url
        case .workshop(let item): item.localFolder
        }
    }

    var libraryFileSize: Int {
        switch origin {
        case .remote(let wallpaper): wallpaper.fileSize
        case .local(let item): item.fileSize
        case .workshop(let item): item.fileSize
        }
    }

    func matchesLibrarySearch(_ query: String) -> Bool {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return true }
        if libraryTitle.localizedCaseInsensitiveContains(keyword) { return true }
        return workshop?.tags.contains { $0.localizedCaseInsensitiveContains(keyword) || WorkshopTags.label(for: $0).contains(keyword) } ?? false
    }
}

struct LibraryGridView<MenuItems: View>: View {
    @ObservedObject var liveController: LiveWallpaperController

    let items: [GalleryItem]
    let selectedID: String?
    let size: CGSize
    @Binding var columnCount: Int
    let onSelect: (GalleryItem) -> Void
    let onApply: (GalleryItem) -> Void
    let onDelete: (GalleryItem, _ unsubscribe: Bool) -> Void
    let onHover: (String, Bool) -> Void
    @ViewBuilder let contextMenu: (GalleryItem) -> MenuItems

    private let spacing: CGFloat = 10
    private let panelWidth: CGFloat = 300
    private let minTileWidth: CGFloat = 170
    private let edgePadding: CGFloat = 16

    private var columns: Int {
        let gridWidth = size.width - panelWidth - edgePadding * 3
        return max(2, Int((gridWidth + spacing) / (minTileWidth + spacing)))
    }

    var body: some View {
        HStack(alignment: .top, spacing: edgePadding) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
                        spacing: spacing
                    ) {
                        ForEach(items) { item in
                            LibraryTile(item: item, isSelected: item.id == selectedID, isLive: isLive(item))
                                .id(item.id)
                                .onTapGesture { onSelect(item) }
                                .contextMenu { contextMenu(item) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id) }
                }
            }
            .frame(maxWidth: .infinity)
            .onHover { onHover("grid", $0) }

            Group {
                if let selected = items.first(where: { $0.id == selectedID }) {
                    LibraryDetailPanel(
                        item: selected,
                        isLive: isLive(selected),
                        maxHeight: size.height - 74 - edgePadding,
                        onApply: { onApply(selected) },
                        onDelete: { onDelete(selected, $0) }
                    )
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

    private func isLive(_ item: GalleryItem) -> Bool {
        guard let live = liveController.currentURL?.standardizedFileURL else { return false }
        switch item.origin {
        case .local(let local): return local.url.standardizedFileURL == live
        case .workshop(let workshop): return workshop.localFolder?.standardizedFileURL == live
        case .remote: return false
        }
    }
}

// MARK: - Tile

private struct LibraryTile: View {
    let item: GalleryItem
    let isSelected: Bool
    let isLive: Bool

    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        Color.clear
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                KFImage(source: item.thumbnailSource)
                    .setProcessor(item.thumbnailProcessor)
                    .scaleFactor(ImageSizing.scale)
                    .cancelOnDisappear(true)
                    .placeholder { Color.white.opacity(0.06) }
                    .fade(duration: 0.2)
                    .resizable()
                    .scaledToFill()
            }
            .overlay(alignment: .bottomLeading) {
                Text(item.libraryTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            }
            .overlay(alignment: .topLeading) {
                Image(systemName: item.librarySymbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 20, height: 20)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(6)
                    .help(item.libraryKindLabel)
            }
            .overlay(alignment: .topTrailing) {
                if isLive {
                    Text("LIVE")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.green, in: Capsule())
                        .padding(6)
                }
            }
            .clipShape(shape)
            .overlay(shape.stroke(isSelected ? Color.white : Color.white.opacity(isHovered ? 0.35 : 0.12), lineWidth: isSelected ? 2.5 : 1))
            .brightness(isHovered && !isSelected ? 0.05 : 0)
            .contentShape(shape)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Detail panel

private struct LibraryDetailPanel: View {
    @EnvironmentObject private var workshop: WorkshopViewModel
    let item: GalleryItem
    let isLive: Bool
    let maxHeight: CGFloat
    let onApply: () -> Void
    let onDelete: (_ unsubscribe: Bool) -> Void

    private var isAnimated: Bool { item.isVideo || item.workshop != nil }

    var body: some View {
        GlassPanel(width: 300, maxHeight: maxHeight) {
            KFImage(source: item.thumbnailSource)
                .setProcessor(item.thumbnailProcessor)
                .placeholder { Color.white.opacity(0.06) }
                .resizable()
                .scaledToFill()
                .frame(width: 264, height: 165)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(isLive ? "LIVE · 正在桌面播放" : item.libraryKindLabel.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(isLive ? .green : .white.opacity(0.55))
                Text(item.libraryTitle)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            FlowLayout(spacing: 6) {
                if item.libraryFileSize > 0 {
                    chip(ByteCountFormatter.string(fromByteCount: Int64(item.libraryFileSize), countStyle: .file))
                }
                if let local = item.local {
                    chip(local.url.pathExtension.uppercased())
                }
                if let rating = item.workshop?.contentRating {
                    chip(WorkshopRating(rawValue: rating)?.label ?? rating)
                }
            }

            if let tags = item.workshop?.tags, !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        chip("#\(WorkshopTags.label(for: tag))")
                    }
                }
            }

            Button(action: onApply) {
                HStack(spacing: 6) {
                    Image(systemName: isAnimated ? "play.fill" : "photo")
                    Text(isAnimated ? "设为动态壁纸" : "设为壁纸")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("回车")

            HStack(spacing: 8) {
                AddToPlaylistButton(item: item)
                if let url = item.libraryFileURL {
                    CircleIconButton(systemImage: "folder", help: "在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                if let workshopItem = item.workshop, workshop.isSubscribed(workshopItem) {
                    Menu {
                        Button("移到废纸篓") { onDelete(false) }
                        Button("移到废纸篓并取消订阅", role: .destructive) { onDelete(true) }
                    } label: {
                        CircleIconLabel(systemImage: "trash", tint: .red.opacity(0.9))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("删除")
                } else {
                    CircleIconButton(systemImage: "trash", tint: .red.opacity(0.9), help: "移到废纸篓") { onDelete(false) }
                }
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(0.12), in: Capsule())
    }
}
