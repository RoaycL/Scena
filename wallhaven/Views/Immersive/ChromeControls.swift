//
//  ChromeControls.swift
//  wallhaven
//

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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
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
            .background(.ultraThinMaterial, in: Capsule())
            .help(controller.isPaused ? "动态壁纸已暂停" : "动态壁纸正在桌面播放：\(content.title)")
        }
    }
}

/// 统一的状态角标：红色爱心 = 已收藏 / 已订阅，绿色对勾 = 已下载到本地
struct StatusBadges: View {
    var isFavorite = false
    var isDownloaded = false
    var size: CGFloat = 18

    var body: some View {
        HStack(spacing: 4) {
            if isFavorite { badge("heart.fill", color: .red, help: "已收藏 / 已订阅") }
            if isDownloaded { badge("checkmark", color: .green, help: "已下载到本地") }
        }
    }

    private func badge(_ symbol: String, color: Color, help: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.opacity(0.9), in: Circle())
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .help(help)
    }
}
