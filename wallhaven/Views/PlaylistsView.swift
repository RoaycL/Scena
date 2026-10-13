//
//  PlaylistsView.swift
//  wallhaven
//

import Kingfisher
import SwiftUI

enum PlaylistsWindow {
    static let id = "playlists"
}

/// 播放列表管理窗口：左侧列表，右侧条目（拖动排序、设置间隔和随机）
struct PlaylistsView: View {
    @ObservedObject private var manager = PlaylistManager.shared
    @State private var selectedID: UUID?
    @State private var selectedEntries = Set<String>()
    /// 嵌入主窗口的「播放列表」页签时为 true：不使用 NavigationSplitView，
    /// 否则它会把侧栏按钮放进窗口标题栏，盖住主窗口的页签
    var embedded = false

    var body: some View {
        Group {
            if embedded {
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: 220)
                    Divider()
                    detailContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                NavigationSplitView {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
                } detail: {
                    detailContent
                }
                .frame(minWidth: 680, minHeight: 440)
            }
        }
        .onAppear {
            if selectedID == nil { selectedID = manager.activeID ?? manager.playlists.first?.id }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedID) {
            ForEach(manager.playlists) { playlist in
                HStack(spacing: 8) {
                    Image(systemName: manager.activeID == playlist.id ? "play.circle.fill" : "music.note.list")
                        .foregroundStyle(manager.activeID == playlist.id ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.name).lineLimit(1)
                        Text("\(playlist.entries.count) 张")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(playlist.id)
                .contextMenu {
                    Button(manager.activeID == playlist.id ? "停止" : "播放") { togglePlay(playlist) }
                    Divider()
                    Button("删除", role: .destructive) { manager.delete(playlist.id) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    selectedID = manager.create().id
                } label: {
                    Label("新建播放列表", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let playlist = manager.playlists.first(where: { $0.id == selectedID }) {
            detail(for: playlist)
        } else {
            ContentUnavailableView(
                "选择或新建一个播放列表",
                systemImage: "music.note.list",
                description: Text("在任意壁纸上右键 →「添加到播放列表」")
            )
        }
    }

    private func detail(for playlist: Playlist) -> some View {
        let isActive = manager.activeID == playlist.id

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("名称", text: Binding(
                    get: { playlist.name },
                    set: { manager.rename(playlist.id, to: $0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .bold))

                HStack(spacing: 12) {
                    Button { togglePlay(playlist) } label: {
                        Label(isActive ? "停止" : "播放", systemImage: isActive ? "stop.fill" : "play.fill")
                            .frame(minWidth: 64)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isActive ? .red : .accentColor)
                    .disabled(playlist.entries.isEmpty)

                    if isActive {
                        Button { manager.next() } label: { Label("下一张", systemImage: "forward.fill") }
                    }

                    Picker("切换间隔", selection: Binding(
                        get: { playlist.interval },
                        set: { manager.setInterval($0, for: playlist.id) }
                    )) {
                        ForEach(Playlist.intervals, id: \.seconds) { Text($0.label).tag($0.seconds) }
                    }
                    .fixedSize()

                    Toggle("随机播放", isOn: Binding(
                        get: { playlist.shuffle },
                        set: { manager.setShuffle($0, for: playlist.id) }
                    ))
                    .toggleStyle(.checkbox)
                    .fixedSize()

                    Spacer()

                    if isActive, let next = manager.nextChangeAt {
                        Text("下次切换 \(next.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)

            Divider()

            if playlist.entries.isEmpty {
                ContentUnavailableView(
                    "还没有壁纸",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("在首页、收藏、本地或工坊里右键壁纸 →「添加到播放列表」")
                )
            } else {
                List(selection: $selectedEntries) {
                    ForEach(playlist.entries) { entry in
                        entryRow(entry, isCurrent: isActive && manager.currentEntryID == entry.id)
                            .tag(entry.id)
                            .contextMenu {
                                Button("从这里开始播放") { manager.play(playlist.id, startAt: entry.id) }
                                Divider()
                                Button("移除", role: .destructive) {
                                    manager.remove(selectedEntries.contains(entry.id) ? selectedEntries : [entry.id], from: playlist.id)
                                }
                            }
                    }
                    .onMove { manager.move(in: playlist.id, from: $0, to: $1) }
                    .onDelete { offsets in
                        manager.remove(Set(offsets.map { playlist.entries[$0].id }), from: playlist.id)
                    }
                }
                .onDeleteCommand {
                    manager.remove(selectedEntries, from: playlist.id)
                    selectedEntries.removeAll()
                }
            }
        }
    }

    private func entryRow(_ entry: PlaylistEntry, isCurrent: Bool) -> some View {
        HStack(spacing: 12) {
            KFImage(source: entry.thumbnailURL.map { $0.isFileURL ? .provider(LocalFileImageDataProvider(fileURL: $0)) : $0.convertToSource() })
                .setProcessor(GIFPosterFrameProcessor(maxPixelSize: 240))
                .placeholder {
                    Image(systemName: entry.kind == .workshop ? "cube" : "photo")
                        .foregroundStyle(.secondary)
                }
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 42)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(1)
                Text(entry.kindLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isCurrent {
                Label("当前", systemImage: "speaker.wave.2.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }

    private func togglePlay(_ playlist: Playlist) {
        if manager.activeID == playlist.id {
            manager.stop()
        } else {
            manager.play(playlist.id)
        }
    }
}

/// 「添加到播放列表」的菜单项：各个播放列表 + 新建
struct AddToPlaylistItems: View {
    @ObservedObject private var manager = PlaylistManager.shared
    @Environment(\.openWindow) private var openWindow
    let entry: PlaylistEntry

    var body: some View {
        ForEach(manager.playlists) { playlist in
            Button(playlist.name) { manager.add([entry], to: playlist.id) }
        }
        if !manager.playlists.isEmpty { Divider() }
        Button("新建播放列表…") {
            manager.create(entries: [entry])
            ToastCenter.shared.show("已创建播放列表", style: .success)
            openWindow(id: PlaylistsWindow.id)
        }
    }
}

/// 右键菜单里的「添加到播放列表」子菜单
struct AddToPlaylistMenu: View {
    let item: GalleryItem

    var body: some View {
        if let entry = PlaylistEntry(item) {
            Menu("添加到播放列表") {
                AddToPlaylistItems(entry: entry)
            }
        } else {
            Button("添加到播放列表（需先下载）") {}
                .disabled(true)
        }
    }
}

/// 信息面板 / 详情栏里的「添加到播放列表」圆形按钮
struct AddToPlaylistButton: View {
    let item: GalleryItem

    var body: some View {
        Menu {
            if let entry = PlaylistEntry(item) {
                AddToPlaylistItems(entry: entry)
            }
        } label: {
            CircleIconLabel(systemImage: "text.badge.plus")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("添加到播放列表")
    }
}
