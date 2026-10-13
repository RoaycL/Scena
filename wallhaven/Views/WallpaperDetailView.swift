//
//  WallpaperDetailView.swift
//  wallhaven
//
//  Created by RoaycL on 2026/4/17.
//

import AppKit
import SwiftUI
import Kingfisher

struct WallpaperDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let wallpaper: WallhavenWallpaper
    let isFavorite: Bool
    let onFavorite: () -> Void
    @State private var tags: [String] = []
    @State private var isLoadingTags = true
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("壁纸详情")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            Color.black
                .overlay {
                    KFImage(wallpaper.path)
                        .placeholder {
                            ProgressView()
                        }
                        .resizable()
                        .scaledToFit()
                }
            
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("分辨率: \(wallpaper.resolution)")
                    Text("宽高比: \(wallpaper.ratio)")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text("分类: \(wallpaper.category)")
                    Text("纯净度: \(wallpaper.purity)")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                
                Button {
                    onFavorite()
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(isFavorite ? .red : .primary)
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .padding(.leading, 10)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
        }
        /*
        .overlay(alignment: .bottom) {
            if isLoadingTags {
                ProgressView()
                    .padding()
            } else if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.15))
                                .clipShape(Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    .padding()
                }
                .background(Color.black.opacity(0.6))
            }
        }
        */
        .frame(width: 800, height: 600)
        /*
        .task {
            let client = WallhavenClient()
            let apiKey = UserDefaults.standard.string(forKey: "wallper.wallhaven.apikey")
            do {
                tags = try await client.fetchWallpaperDetails(id: wallpaper.id, apiKey: apiKey)
            } catch {
                print(error)
            }
            isLoadingTags = false
        }
        */
    }
}
