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
    /// 鼠标悬停的缩略图：提亮并轻微放大
    @State private var hoveredID: String?
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
                            .onHover { inside in
                                if inside { hoveredID = item.id } else if hoveredID == item.id { hoveredID = nil }
                            }
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
                withAnimation(Motion.scroll) {
                    proxy.scrollTo(newID)
                }
            }
        }
    }

    private func thumbnail(for item: GalleryItem) -> some View {
        let isSelected = item.id == selectedID
        return RetryingThumbnailImage(item: item)
            // 工坊下载后预览地址会改变，新的来源不能沿用旧请求的失败状态。
            .id("\(item.thumbnailSource?.cacheKey ?? item.id)-\(item.thumbnailProcessor.identifier)")
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
                } else if item.workshop != nil {
                    // 工坊条目：类型图标（是否已下载看右上角的绿色对勾）
                    Image(systemName: item.librarySymbol)
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
            .opacity(isSelected || hoveredID == item.id ? 1 : 0.78)
            .scaleEffect(Motion.reducesMotion ? 1 : (isSelected ? 1.04 : (hoveredID == item.id ? 1.02 : 1)))
            .shadow(color: .black.opacity(isSelected ? 0.45 : 0), radius: 10, y: 4)
            .animation(Motion.hover, value: isSelected)
            .animation(Motion.hover, value: hoveredID == item.id)
            .contentShape(Rectangle())
    }
}


/// 缩略图加载兜底：只请求屏幕上看得见的卡片，但被中断或失败的会自动补上，不会一直空白。
///  - 滑出屏幕就取消请求，长列表快速滚动时不堆积下载；
///  - 被取消的卡片：等重新出现时再请求（仍在屏幕上的，稍后复查一次）；
///  - 真正失败的：自动重试 2 次，仍失败再显示「重试」按钮。
private struct RetryingThumbnailImage: View {
    let item: GalleryItem
    @State private var generation = 0
    @State private var automaticRetries = 0
    @State private var isVisible = false
    @State private var isLoaded = false
    @State private var needsReloadOnAppear = false
    @State private var cancelCheckID: UUID?
    @State private var failureID: UUID?
    @State private var failureMessage: String?

    var body: some View {
        let attempt = generation
        KFImage(source: item.thumbnailSource)
            .setProcessor(item.thumbnailProcessor)
            .scaleFactor(ImageSizing.scale)
            .cancelOnDisappear(true)
            // 加载中只用淡色占位；转圈只在重试时出现，避免一屏几十个同时转
            .placeholder { Color.white.opacity(0.08) }
            .fade(duration: Motion.reducesMotion ? 0 : 0.2)
            .onSuccess { _ in
                guard generation == attempt else { return }
                isLoaded = true
                needsReloadOnAppear = false
                failureID = nil
                failureMessage = nil
                automaticRetries = 0
            }
            .onFailure { error in
                guard generation == attempt, !isLoaded else { return }
                if error.isTaskCancelled {
                    // 被取消（滑出屏幕、列表刷新）：等卡片重新出现时补请求。
                    // 取消回调是异步的，卡片可能已经重新出现了，所以稍后再看一眼（见下面的 task）
                    needsReloadOnAppear = true
                    cancelCheckID = UUID()
                    return
                }
                failureMessage = error.localizedDescription
                failureID = UUID()
            }
            .resizable()
            .scaledToFill()
            // 换编号强制重新请求。编号必须全局唯一：懒加载列表里各卡片若都用 0、1 这种重复的 id，
            // 布局只会创建第一张卡片
            .id("\(item.id)#\(attempt)")
            .onAppear {
                isVisible = true
                if needsReloadOnAppear, !isLoaded {
                    needsReloadOnAppear = false
                    reload()
                }
            }
            .onDisappear { isVisible = false }
            .overlay {
                if failureID != nil {
                    if automaticRetries < 2 {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Button {
                            automaticRetries = 0
                            reload()
                        } label: {
                            Label("重试", systemImage: "arrow.clockwise")
                                .font(.caption)
                                .foregroundStyle(.white)
                                .padding(6)
                                .background(.black.opacity(0.5), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(failureMessage ?? "重新加载缩略图")
                        .accessibilityLabel("重新加载缩略图")
                    }
                }
            }
            .task(id: cancelCheckID) {
                // 延迟复查，而不是立即重载：懒加载列表在布局时会反复创建、移除卡片，立即重载会和它互相触发
                guard cancelCheckID != nil else { return }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard isVisible, needsReloadOnAppear, !isLoaded, generation == attempt else { return }
                needsReloadOnAppear = false
                reload()
            }
            .task(id: failureID) {
                guard let failureID, automaticRetries < 2 else { return }
                do {
                    try await Task.sleep(for: .milliseconds(automaticRetries == 0 ? 400 : 1000))
                } catch { return }
                guard self.failureID == failureID else { return }
                automaticRetries += 1
                reload()
            }
    }

    private func reload() {
        failureID = nil
        failureMessage = nil
        generation += 1
    }
}
