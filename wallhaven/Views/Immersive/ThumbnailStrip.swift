//
//  ThumbnailStrip.swift
//  wallhaven
//

import Kingfisher
import SwiftUI

struct ThumbnailStrip<MenuItems: View>: View {
    let items: [GalleryItem]
    let selectedID: String?
    let selectionWithoutScrollingID: String?
    let isLoading: Bool
    let thumbHeight: CGFloat
    let onSelect: (GalleryItem) -> Void
    var onItemAppear: (GalleryItem) -> Void = { _ in }
    /// 双击缩略图（设为壁纸）
    var onActivate: (GalleryItem) -> Void = { _ in }
    /// 加载失败时末尾显示「重试」
    var loadError: String? = nil
    var onRetry: () -> Void = {}
    /// 工坊条目的下载状态（显示「下载中 / 排队中」遮罩）
    var downloadState: (GalleryItem) -> DownloadState = { _ in .none }
    @ViewBuilder let contextMenu: (GalleryItem) -> MenuItems

    private let corner: CGFloat = 10
    private var thumbWidth: CGFloat { thumbHeight * 16 / 9 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(items) { item in
                        thumbnail(for: item)
                            .id(item.id)
                            // 单击立即选中；双击另外识别，不让单击等待双击判定
                            .onTapGesture { onSelect(item) }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { onActivate(item) })
                            .contextMenu { contextMenu(item) }
                            .onAppear { onItemAppear(item) }
                    }
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                            .frame(width: thumbWidth * 0.4, height: thumbHeight)
                    } else if let loadError {
                        Button(action: onRetry) {
                            VStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 18, weight: .semibold))
                                Text("加载失败，点击重试")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: thumbWidth * 0.8, height: thumbHeight)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: corner, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(loadError)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(height: thumbHeight + 20)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .onChange(of: selectedID) { _, newID in
                guard let newID, newID != selectionWithoutScrollingID else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private func thumbnail(for item: GalleryItem) -> some View {
        let isSelected = item.id == selectedID
        return KFImage(source: item.thumbnailSource)
            .setProcessor(item.thumbnailProcessor)
            .scaleFactor(ImageSizing.scale)
            .cancelOnDisappear(true)
            .placeholder { Color.white.opacity(0.08) }
            .fade(duration: 0.2)
            .resizable()
            .scaledToFill()
            .frame(width: thumbWidth, height: thumbHeight)
            .overlay {
                let state = downloadState(item)
                if state == .queued || state == .downloading {
                    DownloadingOverlay(state: state)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                        .padding(6)
                } else if let workshopItem = item.workshop {
                    // 工坊条目：类型图标；未下载时显示下载箭头
                    Image(systemName: workshopItem.isDownloaded ? item.librarySymbol : "arrow.down.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(isSelected ? Color.white : Color.white.opacity(0.18), lineWidth: isSelected ? 2.5 : 1)
            )
            .opacity(isSelected ? 1 : 0.78)
            .scaleEffect(isSelected ? 1.04 : 1)
            .animation(.spring(response: 0.3), value: isSelected)
            .contentShape(Rectangle())
    }
}
