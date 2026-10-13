//
//  LocalMediaCard.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import AppKit
import SwiftUI
import Kingfisher

struct LocalMediaCard: View {
    let item: LocalMediaItem
    let isSelected: Bool
    let onTap: () -> Void
    let onSetAsWallpaper: () -> Void
    let onDelete: () -> Void
    let onShowInFinder: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear
                .aspectRatio(16/10, contentMode: .fit)
                .overlay {
                    if let nsImage = NSImage(contentsOf: item.url) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .overlay {
                                Image(systemName: "photo")
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isSelected ? Color.white : Color.white.opacity(0.08), lineWidth: isSelected ? 3 : 1)
                )

            HStack {
                Text(item.url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
            }
            .padding(.horizontal, 4)
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
            Button("设为壁纸") { onSetAsWallpaper() }
            Button("在访达中显示") { onShowInFinder() }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Text("删除")
            }
        }
    }
}
