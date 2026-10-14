//
//  InfoPanel.swift
//  wallhaven
//

import SwiftUI

/// 左下角的信息面板：直接压在壁纸上（靠底部渐变保证可读性），不再使用黑色底框
struct InfoPanel<Actions: View>: View {
    let eyebrow: String
    let title: String
    let meta: [String]
    var colors: [String] = []
    var tags: [String] = []
    var onTag: ((String) -> Void)? = nil
    var tagLabel: (String) -> String = { $0 }
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow)
                .font(.system(size: 10, weight: .bold))
                .tracking(2.5)
                .foregroundStyle(.white.opacity(0.6))

            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)

            HStack(spacing: 8) {
                ForEach(Array(meta.enumerated()), id: \.offset) { index, value in
                    if index > 0 { Text("·").opacity(0.5) }
                    Text(value)
                }
                if !colors.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(colors.prefix(5), id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 0.5))
                                .help(hex)
                        }
                    }
                    .padding(.leading, 4)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))

            if !tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(tags.prefix(5), id: \.self) { tag in
                        Button { onTag?(tag) } label: {
                            Text("#\(tagLabel(tag))")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(.white.opacity(0.12), in: Capsule())
                                .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .help("搜索 \(tag)")
                    }
                }
                .lineLimit(1)
                .transition(.opacity)
            }

            HStack(spacing: 8) {
                actions()
            }
            .padding(.top, 4)
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        .animation(Motion.content, value: tags)
    }
}

struct PrimaryActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.white, in: Capsule())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

struct CircleIconLabel: View {
    let systemImage: String
    var tint: Color = .white

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 0.5))
    }
}

struct CircleIconButton: View {
    let systemImage: String
    var tint: Color = .white
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CircleIconLabel(systemImage: systemImage, tint: tint)
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
    }
}

/// 收藏按钮：点击菜单可选择收藏夹
struct FavoriteMenuButton: View {
    @EnvironmentObject private var viewModel: WallpaperViewModel
    let wallpaper: WallhavenWallpaper

    var body: some View {
        let isFavorite = viewModel.isFavorite(wallpaper.id)
        Menu {
            if !viewModel.favoriteFolders.isEmpty {
                let containing = Set(viewModel.foldersContaining(wallpaper.id).map(\.id))
                ForEach(viewModel.favoriteFolders) { folder in
                    let inFolder = containing.contains(folder.id)
                    Button {
                        inFolder
                            ? viewModel.removeFromFolder(wallpaper.id, folderID: folder.id)
                            : viewModel.addToFolder(wallpaper, folderID: folder.id)
                    } label: {
                        Label(folder.name, systemImage: inFolder ? "checkmark.circle.fill" : "folder")
                    }
                }
                Divider()
            }
            Button(role: isFavorite ? .destructive : nil) {
                viewModel.toggleFavorite(wallpaper)
            } label: {
                Label(isFavorite ? "取消收藏" : "添加到默认收藏", systemImage: isFavorite ? "heart.slash" : "heart")
            }
        } label: {
            CircleIconLabel(systemImage: isFavorite ? "heart.fill" : "heart", tint: isFavorite ? .red : .white)
        }
        // .button + .plain 才能保留自定义 label 的样式（borderlessButton 会把背景去掉）
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("收藏")
    }
}

extension Color {
    /// 支持 "#RRGGBB" 格式
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// 按下时轻微缩小、悬停时提亮，松开回弹；所有主要按钮共用，手感一致
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration)
    }

    private struct PressableBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .brightness(isHovered && !configuration.isPressed ? 0.08 : 0)
                .animation(Motion.hover, value: configuration.isPressed)
                .animation(Motion.hover, value: isHovered)
                .onHover { isHovered = $0 }
        }
    }
}
