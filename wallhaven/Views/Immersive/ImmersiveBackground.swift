//
//  ImmersiveBackground.swift
//  wallhaven
//

import Kingfisher
import SwiftUI

/// 全窗口背景：切换时新旧两张交叉淡化；
/// 每张先用已缓存的缩略图模糊放大顶上，原图加载完成后再淡入
struct ImmersiveBackground: View {
    let item: GalleryItem?

    var body: some View {
        ZStack {
            Color.black
            if let item {
                BackgroundLayer(item: item)
                    .id(item.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: item?.id)
        .clipped()
    }
}

private struct BackgroundLayer: View {
    let item: GalleryItem
    @State private var isFullLoaded = false

    /// 未下载的工坊条目只有一张小尺寸方形预览图（391～1024px），不能直接铺满窗口
    private var onlinePreviewItem: WorkshopItem? {
        guard let workshop = item.workshop, !workshop.isDownloaded else { return nil }
        return workshop
    }

    var body: some View {
        GeometryReader { geo in
            if let workshop = onlinePreviewItem {
                OnlinePreviewShowcase(item: item, workshop: workshop, size: geo.size)
            } else {
                layers(in: geo.size)
            }
        }
    }

    private func layers(in size: CGSize) -> some View {
        ZStack {
            if let thumb = item.thumbnailSource, !isFullLoaded {
                KFImage(source: thumb)
                    .setProcessor(item.thumbnailProcessor)
                    .scaleFactor(ImageSizing.scale)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .blur(radius: 28, opaque: true)
                    .scaleEffect(1.08)
            }

            if item.isVideo, let url = item.local?.url {
                LoopingVideoView(url: url)
                    .frame(width: size.width, height: size.height)
            } else if let workshopItem = item.playableWorkshopItem {
                // 工坊壁纸实时渲染；首帧出来之前保留模糊封面
                WorkshopPlayerView(item: workshopItem) { state in
                    if state == .ready {
                        withAnimation(.easeInOut(duration: 0.4)) { isFullLoaded = true }
                    }
                }
                .frame(width: size.width, height: size.height)
                .opacity(isFullLoaded ? 1 : 0)
            } else if let full = item.fullSource {
                KFImage(source: full)
                    .setProcessor(DownsamplingImageProcessor(size: ImageSizing.backgroundSize))
                    .scaleFactor(ImageSizing.scale)
                    .fade(duration: 0.35)
                    .onSuccess { _ in
                        // 等淡入结束再移除模糊占位
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            isFullLoaded = true
                        }
                    }
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

/// 在线工坊条目的预览：模糊铺底做氛围色 + 接近原始尺寸的清晰预览卡片（GIF 会播放动画）
private struct OnlinePreviewShowcase: View {
    let item: GalleryItem
    let workshop: WorkshopItem
    let size: CGSize

    var body: some View {
        // 不超过预览图的原始尺寸太多（方图最大 1024px ≈ Retina 下 512pt，适度放大到 560pt 仍清晰）
        let side = min(size.height * 0.56, size.width * 0.4, 560)

        ZStack {
            if let thumb = item.thumbnailSource {
                KFImage(source: thumb)
                    .setProcessor(item.thumbnailProcessor)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .blur(radius: 60, opaque: true)
                    .scaleEffect(1.2)
                    .overlay(Color.black.opacity(0.35))
            }

            VStack(spacing: 10) {
                ZStack {
                    // 静态预览（缩略图条已缓存，立即显示）
                    KFImage(source: item.thumbnailSource)
                        .setProcessor(item.thumbnailProcessor)
                        .placeholder { Color.white.opacity(0.06) }
                        .resizable()
                        .scaledToFit()
                    // 动态预览：GIF 由 NSImageView 原生播放
                    if let url = workshop.previewURL {
                        AnimatedPreviewImage(url: url)
                    }
                }
                .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.15), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 30, y: 14)

                Label("预览图 · 下载后实时渲染全画质", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            // 放在右上区域，避开左下角的信息面板和底部缩略图条
            .position(x: size.width * 0.66, y: size.height * 0.42)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

/// 用 NSImageView 播放 GIF 预览（加载完成前透明，露出下层的静态图）
private struct AnimatedPreviewImage: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        context.coordinator.load(url, into: view)
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {}

    static func dismantleNSView(_ nsView: NSImageView, coordinator: Coordinator) {
        coordinator.task?.cancel()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var task: Task<Void, Never>?

        func load(_ url: URL, into view: NSImageView) {
            task = Task { [weak view] in
                // URLSession 默认带 URLCache，重复查看不会重复下载
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      !Task.isCancelled,
                      let image = NSImage(data: data) else { return }
                view?.image = image
            }
        }
    }
}
