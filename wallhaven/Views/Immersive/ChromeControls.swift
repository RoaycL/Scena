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

/// 筛选面板：分类、纯度、排序合并到一个弹出面板里，顶栏只留一个按钮
struct FilterPanel: View {
    @EnvironmentObject private var viewModel: WallpaperViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("分类") {
                chip("常规", isOn: viewModel.includeGeneral, action: viewModel.toggleGeneral)
                chip("动漫", isOn: viewModel.includeAnime, action: viewModel.toggleAnime)
                chip("人物", isOn: viewModel.includePeople, action: viewModel.togglePeople)
            }

            section("内容分级") {
                chip("SFW", isOn: viewModel.includeSFW, tint: .green, action: viewModel.toggleSFW)
                chip("Sketchy", isOn: viewModel.includeSketchy, tint: .yellow, disabled: !viewModel.isAuthenticated, action: viewModel.toggleSketchy)
                chip("NSFW", isOn: viewModel.includeNSFW, tint: .red, disabled: !viewModel.isAuthenticated, action: viewModel.toggleNSFW)
            }
            if !viewModel.isAuthenticated {
                Text("登录后可开启 Sketchy / NSFW")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("排序").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("排序", selection: $viewModel.sortOrder) {
                    ForEach(SortOrder.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 160)
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 6) { content() }
        }
    }

    private func chip(_ title: String, isOn: Bool, tint: Color = .accentColor, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isOn ? .white : .primary)
                .background(isOn ? tint.opacity(0.85) : Color.primary.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
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
