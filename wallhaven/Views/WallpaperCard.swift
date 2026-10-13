//
//  WallpaperCard.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import AppKit
import SwiftUI
import Kingfisher

struct WallpaperCard: View {
    let wallpaper: WallhavenWallpaper
    let selectedID: String?
    let isFavorite: Bool
    let folders: [FavoriteFolder]
    let containingFolders: [FavoriteFolder]
    let onTap: () -> Void
    let onFavorite: () -> Void
    let onSetAsWallpaper: () -> Void
    let onDownload: () -> Void
    let onShowDetails: () -> Void
    let onAddToFolder: (UUID) -> Void
    let onRemoveFromFolder: (UUID) -> Void
    let onNewFolder: () -> Void

    private var isSelected: Bool {
        selectedID == wallpaper.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear
                .aspectRatio(16/10, contentMode: .fit)
                .overlay {
                    KFImage(wallpaper.thumbURL ?? wallpaper.path)
                        .placeholder {
                            Rectangle()
                                .fill(Color.white.opacity(0.08))
                                .overlay { ProgressView().tint(.white) }
                        }
                        .resizable()
                        .scaledToFill()
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isSelected ? .blue : .white.opacity(0.08), lineWidth: isSelected ? 2 : 1)
                )

            HStack {
                Text(wallpaper.resolution)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()

                Button {
                    onFavorite()
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(isFavorite ? .red : .white.opacity(0.8))
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 6)
        }
        .padding(.bottom, 8)
        .background(Color.white.opacity(1e-5))
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .contextMenu {
            Button("查看详情") { onShowDetails() }
            Button("设为壁纸") { onSetAsWallpaper() }
            Button("下载原图") { onDownload() }
            Divider()
            Button(isFavorite ? "取消收藏" : "收藏") { onFavorite() }
            
            if !folders.isEmpty {
                Menu("收藏到收藏夹...") {
                    ForEach(folders) { folder in
                        let isInFolder = containingFolders.contains(where: { $0.id == folder.id })
                        Button {
                            if isInFolder {
                                onRemoveFromFolder(folder.id)
                            } else {
                                onAddToFolder(folder.id)
                            }
                        } label: {
                            HStack {
                                Text(folder.name)
                                if isInFolder {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    Divider()
                    Button {
                        onNewFolder()
                    } label: {
                        Label("新建收藏夹...", systemImage: "plus")
                    }
                }
            } else {
                Button {
                    onNewFolder()
                } label: {
                    Label("新建收藏夹并收藏", systemImage: "folder.badge.plus")
                }
            }
        }
        .scaleEffect(isSelected ? 0.98 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}

#Preview {
    ContentView()
        .environmentObject(WallpaperViewModel())
}
