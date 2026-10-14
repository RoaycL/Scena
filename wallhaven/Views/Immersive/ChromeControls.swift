//
//  ChromeControls.swift
//  wallhaven
//

import AppKit
import Kingfisher
import SwiftUI

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            switch toast.style {
            case .progress:
                ProgressView().controlSize(.small).tint(.white)
            case .success:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            case .info:
                Image(systemName: "info.circle.fill").foregroundStyle(.white.opacity(0.8))
            }
            Text(toast.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
            if toast.action != nil {
                HStack(spacing: 2) {
                    Text(toast.actionTitle)
                    if toast.actionTitle == "查看" { Image(systemName: "chevron.right") }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize()
            }
        }
        .contentShape(Capsule())
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .sceneGlass(in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .environment(\.colorScheme, .dark)
    }
}

/// 筛选面板：分类、纯度、排序合并到一个面板里，顶栏只留一个按钮
struct FilterPanel: View {
    @EnvironmentObject private var viewModel: WallpaperViewModel

    var body: some View {
        GlassPanel(width: 300) {
            Text("筛选")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)

            GlassSection(title: "分类") {
                FlowLayout {
                    GlassChip(title: "常规", isOn: viewModel.includeGeneral, action: viewModel.toggleGeneral)
                    GlassChip(title: "动漫", isOn: viewModel.includeAnime, action: viewModel.toggleAnime)
                    GlassChip(title: "人物", isOn: viewModel.includePeople, action: viewModel.togglePeople)
                }
            }

            GlassSection(title: "内容分级", trailing: viewModel.isAuthenticated ? nil : "登录后可开启 Sketchy / NSFW") {
                FlowLayout {
                    GlassChip(title: "SFW", isOn: viewModel.includeSFW, tint: .green, action: viewModel.toggleSFW)
                    GlassChip(title: "Sketchy", isOn: viewModel.includeSketchy, tint: .orange, disabled: !viewModel.isAuthenticated, action: viewModel.toggleSketchy)
                    GlassChip(title: "NSFW", isOn: viewModel.includeNSFW, tint: .red, disabled: !viewModel.isAuthenticated, action: viewModel.toggleNSFW)
                }
            }

            GlassSection(title: "分辨率", trailing: "可多选") {
                FlowLayout {
                    GlassChip(title: "不限", isOn: viewModel.resolutions.isEmpty) {
                        viewModel.toggleResolution(nil)
                    }
                    ForEach(WallpaperViewModel.resolutionOptions, id: \.self) { resolution in
                        GlassChip(title: resolution.replacingOccurrences(of: "x", with: "×"), isOn: viewModel.resolutions.contains(resolution)) {
                            viewModel.toggleResolution(resolution)
                        }
                    }
                }
            }

            GlassSection(title: "排序") {
                FlowLayout {
                    ForEach(SortOrder.allCases) { option in
                        GlassChip(title: option.label, isOn: viewModel.sortOrder == option) {
                            viewModel.sortOrder = option
                        }
                    }
                }
            }
        }
    }
}

/// 顶栏上的动态壁纸状态
struct LiveWallpaperStatus: View {
    @ObservedObject var controller: LiveWallpaperController

    var body: some View {
        if let content = controller.current {
            Menu {
                Text(content.title)
                Divider()
                Button(controller.isPaused ? "继续播放" : "暂停") { controller.togglePause() }
                Button("停止动态壁纸", role: .destructive) { controller.stop() }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(controller.isPaused ? Color.orange : Color.green)
                        .frame(width: 7, height: 7)
                    Text("LIVE")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize()
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .sceneGlass(in: Capsule())
            .help(controller.isPaused ? "动态壁纸已暂停" : "动态壁纸正在桌面播放：\(content.title)")
        }
    }
}


/// 页面级加载提示：搜索、筛选、翻页时统一显示在顶部栏下方居中的玻璃胶囊
struct PageLoadingCapsule: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(.white)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .sceneGlass(in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .environment(\.colorScheme, .dark)
    }
}

/// 大图还没显示时的背景：用当前壁纸的缩略图做成强模糊的磨砂底，颜色和即将出现的画面一致；
/// 还没有缩略图时是深色渐变
struct FrostedBackdrop: View {
    let item: GalleryItem?

    var body: some View {
        ZStack {
            WindowFrostedGlass()
            // 无缩略图时也有真实桌面透色，浅亮的上沿让加载占位保留玻璃质感。
            LinearGradient(
                colors: [.white.opacity(0.10), Color(red: 0.45, green: 0.55, blue: 0.68).opacity(0.05), .black.opacity(0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            if let item, let source = item.thumbnailSource {
                KFImage(source: source)
                    .setProcessor(item.thumbnailProcessor)
                    .scaleFactor(ImageSizing.scale)
                    .cancelOnDisappear(true)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 60, opaque: true)
                    .saturation(1.15)
                    .overlay(Color.black.opacity(0.3))
                    .id(item.id)
                    .transition(.opacity)
            }
        }
        .clipped()
        .animation(Motion.content, value: item?.id)
    }
}


/// 窗口后的原生磨砂材质，首次启动无需等待图片就能显示。
private struct WindowFrostedGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
