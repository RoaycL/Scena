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

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let thumb = item.thumbnailSource, !isFullLoaded {
                    KFImage(source: thumb)
                        .setProcessor(item.thumbnailProcessor)
                        .scaleFactor(ImageSizing.scale)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 28, opaque: true)
                        .scaleEffect(1.08)
                }

                if item.isVideo, let url = item.local?.url {
                    LoopingVideoView(url: url)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if let workshopItem = item.playableWorkshopItem {
                    // 工坊壁纸实时渲染；首帧出来之前保留模糊封面
                    WorkshopPlayerView(item: workshopItem) { state in
                        if state == .ready {
                            withAnimation(.easeInOut(duration: 0.4)) { isFullLoaded = true }
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
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
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }
}
