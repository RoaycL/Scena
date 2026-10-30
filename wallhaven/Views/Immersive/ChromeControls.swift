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
                ProgressView().controlSize(.small).tint(.primary)
            case .success:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            case .info:
                Image(systemName: "info.circle.fill").foregroundStyle(Color.primary.opacity(0.8))
            }
            Text(toast.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary)
                .lineLimit(2)
            if toast.action != nil {
                HStack(spacing: 2) {
                    Text(toast.actionTitle)
                    if toast.actionTitle == "查看" { Image(systemName: "chevron.right") }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.75))
                .fixedSize()
            }
        }
        .contentShape(Capsule())
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .sceneGlass(in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

/// 筛选面板：筛选项、排序合并到一个面板里，顶栏只留一个按钮（图源在顶部页签的来源菜单里切换）。
/// 筛选项由当前图源的 descriptor 生成，新增图源不需要改这里
struct FilterPanel: View {
    @EnvironmentObject private var viewModel: WallpaperViewModel

    var body: some View {
        GlassPanel(width: 300) {
            Text("筛选")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.primary)

            ForEach(viewModel.activeFilters) { filter in
                let note = viewModel.isSourceAuthenticated ? filter.note : (filter.signedOutNote ?? filter.note)
                GlassSection(title: filter.title, trailing: note) {
                    if filter.input == .choices {
                      FlowLayout {
                        if filter.allowsEmptySelection {
                            GlassChip(title: "不限", isOn: viewModel.filterSelections[filter.id]?.isEmpty ?? true) {
                                viewModel.toggle(nil, in: filter)
                            }
                        }
                        ForEach(filter.options) { option in
                            GlassChip(title: option.title, isOn: viewModel.isSelected(option, in: filter),
                                      tint: option.tint.map(Self.color), disabled: !viewModel.isAvailable(option)) {
                                viewModel.toggle(option, in: filter)
                            }
                        }
                      }
                    } else {
                        SourceFilterFields(filter: filter)
                            .disabled(filter.requiresAccount && !viewModel.isSourceAuthenticated)
                    }
                }
            }

            if viewModel.activeSorts.count > 1 {
                GlassSection(title: "排序") {
                    FlowLayout {
                        ForEach(viewModel.activeSorts) { option in
                            GlassChip(title: option.title, isOn: viewModel.sortID == option.id, disabled: !viewModel.isAvailable(option)) {
                                viewModel.selectSort(option)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func color(_ tint: SourceOption.Tint) -> Color {
        switch tint {
        case .green: .green
        case .orange: .orange
        case .red: .red
        }
    }
}

/// 顶栏上的动态壁纸状态
struct LiveWallpaperStatus: View {
    @ObservedObject var controller: LiveWallpaperController
    @AppStorage(DesktopSettings.webDesktopInput) private var desktopInput: WebDesktopInputMode = .off

    var body: some View {
        if let content = controller.current {
            Menu {
                Text(content.title)
                Divider()
                if controller.canInteract {
                    Button(controller.isInteracting ? "退出网页交互（Esc）" : "进入网页壁纸交互") {
                        if controller.isInteracting { controller.endInteraction() }
                        else { controller.beginInteraction() }
                    }
                    Picker("在桌面上直接操作", selection: $desktopInput) {
                        ForEach(WebDesktopInputMode.allCases) { Text($0.shortTitle).tag($0) }
                    }
                    Divider()
                }
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
                        .foregroundStyle(Color.primary.opacity(0.85))
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
            ProgressView().controlSize(.small).tint(.primary)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.9))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .sceneGlass(in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

/// 大图还没显示时的背景：用当前壁纸的缩略图做成强模糊的磨砂底，颜色和即将出现的画面一致；
/// 还没有缩略图时是深色渐变
struct FrostedBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    private var palette: ThemePalette { ThemePalette(scheme: scheme) }
    let item: GalleryItem?

    var body: some View {
        ZStack {
            ScenaWindowGlass()
            // 无缩略图时也有真实桌面透色，浅亮的上沿让加载占位保留玻璃质感。
            LinearGradient(
                colors: [palette.scrim.opacity(palette.isDay ? 0.20 : 0.08), Color.accentColor.opacity(0.04), palette.scrim.opacity(0.08)],
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
                    .overlay(palette.scrim.opacity(palette.isDay ? 0.48 : 0.3))
                    .id(item.id)
                    .transition(.opacity)
            }
        }
        .clipped()
        .animation(Motion.content, value: item?.id)
    }
}
