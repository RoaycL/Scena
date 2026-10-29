//
//  ImmersiveBackground.swift
//  wallhaven
//

import Kingfisher
import SwiftUI

/// 全窗口背景：保留当前清晰画面，下一张图片或动态首帧就绪后再交叉淡化。
struct ImmersiveBackground: View {
    let item: GalleryItem?
    /// 未下载的工坊条目是否显示预览卡片（网格页面里预览在右侧详情栏，界面隐藏时才显示）
    var showsPreviewCard = true
    /// 卡片居中；否则放在右上区域，避开左下角的信息面板
    var centersPreviewCard = true
    /// 首帧就绪前垫在下面的黑底；调用方自己提供占位图（如缩略图）时关掉
    var showsBlackBase = true
    var onDisplayed: (GalleryItem) -> Void = { _ in }

    var onFailed: (GalleryItem) -> Void = { _ in }
    var retryToken = 0
    var staticOnly = false

    @State private var displayedItem: GalleryItem?
    @State private var requestedID: String?
    /// 每层保留自己的重试编号；切换选择不能重建上一张清晰画面。
    @State private var layerAttempts: [String: Int] = [:]

    private var layers: [GalleryItem] {
        if let displayedItem, let item, displayedItem.id != item.id { return [displayedItem, item] }
        return [item ?? displayedItem].compactMap { $0 }
    }

    var body: some View {
        ZStack {
            if showsBlackBase { Color.black }
            ForEach(layers) { candidate in
                let attempt = layerAttempts[candidate.id, default: 0]
                BackgroundLayer(item: candidate, staticOnly: staticOnly, showsPreviewCard: showsPreviewCard, centersPreviewCard: centersPreviewCard, onFailure: {
                    DispatchQueue.main.async {
                        guard requestedID == candidate.id, layerAttempts[candidate.id, default: 0] == attempt else { return }
                        onFailed(candidate)
                    }
                }) {
                    // 回调可能来自上一轮的加载任务，只提交当前请求的清晰画面。
                    DispatchQueue.main.async {
                        guard requestedID == candidate.id, layerAttempts[candidate.id, default: 0] == attempt else { return }
                        withAnimation(Motion.content) {
                            displayedItem = candidate
                            onDisplayed(candidate)
                        }
                    }
                }
                .id("\(candidate.id)-\(attempt)")
                .opacity(displayedItem?.id == candidate.id ? 1 : 0)
                // 新画面从略带模糊过渡到清晰（不缩放，缩放会显得像突然缩回原图）；减少动态效果时只淡入
                .blur(radius: displayedItem?.id == candidate.id || Motion.reducesMotion ? 0 : 10)
                .transition(.opacity)
            }
        }
        .onChange(of: item?.id, initial: true) {
            requestedID = item?.id
            if let displayedItem, displayedItem.id == item?.id { onDisplayed(displayedItem) }
        }
        .onChange(of: retryToken) {
            guard let item else { return }
            layerAttempts[item.id, default: 0] += 1
        }
        .clipped()
    }
}

private struct BackgroundLayer: View {
    @AppStorage(WorkshopPlaybackPolicy.convertedVideoKey) private var useConvertedVideo = false
    let item: GalleryItem
    let staticOnly: Bool
    let showsPreviewCard: Bool
    let centersPreviewCard: Bool
    let onFailure: () -> Void
    let onReady: () -> Void

    /// 未下载的工坊条目只有一张小尺寸方形预览图（391～1024px），不能直接铺满窗口
    private var onlinePreviewItem: WorkshopItem? {
        guard let workshop = item.workshop, !workshop.isDownloaded else { return nil }
        return workshop
    }

    @State private var isLiveReady = false
    @State private var remoteVideoURL: URL?
    @State private var liveFailed = false
    @State private var hasSignalledReady = false

    /// 封面或动态画面任意一个先就绪，就通知外层切换到这一层
    private func signalReady() {
        guard !hasSignalledReady else { return }
        hasSignalledReady = true
        onReady()
    }

    /// slow：从模糊底色过渡到动态画面时淡入慢一些，像逐渐对上焦
    private func liveDidBecomeReady(slow: Bool = false) {
        withAnimation(slow && !Motion.reducesMotion ? .smooth(duration: 0.7) : Motion.content) { isLiveReady = true }
        signalReady()
    }

    /// 工坊动态壁纸的预览图多为方形 GIF，铺满窗口会被大幅裁切放大，和随后淡入的动态画面构图不一致。
    /// 因此只把它当作模糊的氛围底色：看不出裁切，动态画面渲染好后从模糊中清晰浮现；
    /// 渲染失败时，在底色上按原始比例显示清晰的预览图
    private func ambientPoster(size: CGSize) -> some View {
        poster(size: size)
            .blur(radius: 48, opaque: true)
            .overlay(Color.black.opacity(0.2))
            .overlay {
                if liveFailed {
                    let side = min(size.height * 0.56, size.width * 0.4, 560)
                    KFImage(source: item.thumbnailSource)
                        .setProcessor(item.thumbnailProcessor)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: side, maxHeight: side)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
                        .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
                        .transition(.opacity)
                }
            }
    }

    /// 视频文件本身的有尺寸上限的海报；读不出来时退回壁纸预览图的模糊底色
    private func videoPoster(_ url: URL, size: CGSize) -> some View {
        KFImage(source: .provider(VideoPosterProvider(url: url, tier: .poster)))
            .setProcessor(DownsamplingImageProcessor(size: ImageSizing.backgroundSize))
            .scaleFactor(ImageSizing.scale)
            .loadDiskFileSynchronously(false)
            .cancelOnDisappear(true)
            .onSuccess { _ in signalReady() }
            .placeholder { ambientPoster(size: size) }
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    /// 动态壁纸的封面：清晰显示（不模糊），读取失败时什么也不显示，由外层保留上一张
    private func poster(size: CGSize) -> some View {
        KFImage(source: item.local.flatMap { $0.isVideo ? Source.provider(VideoPosterProvider(url: $0.url, tier: .poster)) : nil }
                ?? (item.remote?.isVideo == true ? item.fullSource : nil) ?? item.thumbnailSource)
            // 工坊预览图与缩略图共享处理器；本地视频使用独立的大图海报缓存。
            .setProcessor(item.workshop != nil ? item.thumbnailProcessor : DownsamplingImageProcessor(size: ImageSizing.backgroundSize))
            .scaleFactor(ImageSizing.scale)
            .loadDiskFileSynchronously(false)
            .cancelOnDisappear(true)
            .onSuccess { _ in signalReady() }
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    var body: some View {
        GeometryReader { geo in
            if let workshop = onlinePreviewItem {
                OnlinePreviewShowcase(item: item, workshop: workshop, size: geo.size, showsCard: showsPreviewCard, centered: centersPreviewCard, onFailure: onFailure, onReady: onReady)
            } else {
                layers(in: geo.size)
            }
        }
        .onChange(of: staticOnly) { isLiveReady = false }
        .onChange(of: useConvertedVideo) {
            isLiveReady = false
            liveFailed = false
        }
        .task(id: item.id) {
            guard let remote = item.remote, remote.isVideo else { return }
            if let local = remote.localFileURL { remoteVideoURL = local; return }
            guard let preview = remote.previewVideoURL else { return }
            remoteVideoURL = try? await RemoteVideoCache.shared.localURL(for: preview)
        }
    }

    private func layers(in size: CGSize) -> some View {
        ZStack {
            if item.isVideo, let url = item.local?.url {
                // 视频首帧要几百毫秒：先显示封面帧，视频就绪后淡入
                poster(size: size)
                if !staticOnly {
                    LoopingVideoView(url: url, onReady: { liveDidBecomeReady() })
                        .frame(width: size.width, height: size.height)
                        .opacity(isLiveReady ? 1 : 0)
                }
            } else if let videoURL = item.playableWorkshopItem?.playbackVideoURL(useConvertedVideo: useConvertedVideo) {
                // 工坊视频壁纸：直接用 AVFoundation 硬件解码、从磁盘流式播放（网页渲染器要先把整个文件读进来，大文件很慢）。
                // 封面取视频本身的画面，构图和随后淡入的视频完全一致
                videoPoster(videoURL, size: size)
                if !staticOnly {
                    LoopingVideoView(url: videoURL, onReady: { liveDidBecomeReady() })
                        .id(item.workshop?.localRevision)
                        .frame(width: size.width, height: size.height)
                        .opacity(isLiveReady ? 1 : 0)
                }
            } else if let workshopItem = item.playableWorkshopItem {
                // 场景 / 网页渲染器启动要 1～5 秒：先用预览图铺一层模糊底色，渲染出第一帧后动态画面淡入
                ambientPoster(size: size)
                if !staticOnly {
                    WorkshopPlayerView(item: workshopItem) { state in
                        if state == .ready {
                            liveDidBecomeReady(slow: true)
                        } else if case .failed = state {
                            withAnimation(Motion.content) { liveFailed = true }
                            onFailure()
                        }
                    }
                    .id(workshopItem.localRevision)
                    .frame(width: size.width, height: size.height)
                    .opacity(isLiveReady ? 1 : 0)
                }
            } else if let remote = item.remote, remote.isVideo {
                // 在线视频壁纸：先显示站点的封面图；下载过的播放本地原片，
                // 否则把低分辨率预览下载到缓存再播放（来回切换不重复下载）
                poster(size: size)
                if !staticOnly, let url = remoteVideoURL {
                    LoopingVideoView(url: url, onReady: { liveDidBecomeReady() })
                        .frame(width: size.width, height: size.height)
                        .opacity(isLiveReady ? 1 : 0)
                }
            } else if let full = item.fullSource {
                KFImage(source: full)
                    .setProcessor(DownsamplingImageProcessor(size: ImageSizing.backgroundSize))
                    .scaleFactor(ImageSizing.scale)
                    // 本地图片直接读原文件就很快，背景大图不再写一份到磁盘缓存，额度留给在线图片
                    .cacheMemoryOnly(item.local != nil)
                    .loadDiskFileSynchronously(false)
                    .cancelOnDisappear(true)
                    .onSuccess { _ in onReady() }
                    .onFailure { _ in onFailure() }
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
    let showsCard: Bool
    let centered: Bool
    let onFailure: () -> Void
    let onReady: () -> Void

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
                        .onSuccess { _ in onReady() }
                        .onFailure { _ in onFailure() }
                        .placeholder { Color.white.opacity(0.06) }
                        .resizable()
                        .scaledToFit()
                    // 动态预览：GIF 由 NSImageView 原生播放
                    if let url = workshop.previewURL {
                        AnimatedPreviewImage(url: url)
                    }
                }
                .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                            .stroke(.white.opacity(0.15), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 30, y: 14)

                Label("预览图 · 下载后实时渲染全画质", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .position(x: size.width * (centered ? 0.5 : 0.68), y: size.height * (centered ? 0.5 : 0.4))
            .opacity(showsCard ? 1 : 0)
            .animation(Motion.panel, value: showsCard)
            .animation(Motion.panel, value: centered)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .onAppear { if item.thumbnailSource == nil { onReady() } }
    }
}

/// 用 NSImageView 播放 GIF 预览（加载完成前透明，露出下层的静态图）
struct AnimatedPreviewImage: NSViewRepresentable {
    let url: URL
    /// true：裁切填满（网格方块）；false：完整显示
    var scalesToFill = false

    func makeNSView(context: Context) -> NSImageView {
        let view = scalesToFill ? FillImageView() : NSImageView()
        view.animates = true
        view.imageScaling = scalesToFill ? .scaleAxesIndependently : .scaleProportionallyUpOrDown
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

    /// 用 layer 的 resizeAspectFill 实现「裁切填满」，NSImageView 本身不支持
    final class FillImageView: NSImageView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.contentsGravity = .resizeAspectFill
            layer?.masksToBounds = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var wantsUpdateLayer: Bool { true }
    }

    final class Coordinator {
        var task: Task<Void, Never>?

        func load(_ url: URL, into view: NSImageView) {
            task = Task { [weak view] in
                // 独立的大容量缓存：重复查看、来回切换不重复下载几 MB 的 GIF
                let data: Data?
                if url.isFileURL {
                    data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
                } else {
                    data = try? await CacheLocations.previewSession.data(from: url).0
                }
                guard let data, !Task.isCancelled,
                      let image = NSImage(data: data) else { return }
                view?.image = image
            }
        }
    }
}
