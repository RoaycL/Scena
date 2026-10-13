//
//  PlaylistsView.swift
//  wallhaven
//

import Kingfisher
import SwiftUI

enum PlaylistsWindow {
    static let id = "playlists"
}

/// 大图预览与横向胶片队列；浏览预览不会立即改变桌面壁纸。
struct PlaylistsView: View {
    @ObservedObject private var manager = PlaylistManager.shared
    @State private var selectedID: UUID?
    @State private var previewEntryID: String?
    @State private var selectedEntries = Set<String>()
    var embedded = false
    var panelWidth: CGFloat = 1180
    var maximumHeight: CGFloat = 820

    private var selectedPlaylist: Playlist? {
        manager.playlists.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let playlist = selectedPlaylist {
                detail(for: playlist)
            } else {
                ContentUnavailableView {
                    Label("创建你的播放列表", systemImage: "photo.stack")
                } description: {
                    Text("将喜欢的壁纸收在一起，按设定的间隔轮换播放。")
                } actions: {
                    Button("新建播放列表…", action: createPlaylist)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24)
        .frame(width: embedded ? panelWidth : nil, height: embedded ? maximumHeight : nil)
        .frame(minWidth: embedded ? nil : 720, minHeight: embedded ? nil : 520)
        .onChange(of: selectedID) {
            selectedEntries.removeAll()
            resetPreview()
        }
        .onChange(of: manager.playlists) { old, new in
            // 移除正在预览的条目时选择原位置的下一张，避免队列回到开头。
            if let selectedID, !new.contains(where: { $0.id == selectedID }) {
                self.selectedID = manager.activeID ?? new.first?.id
                return
            }
            let entries = selectedPlaylist?.entries ?? []
            selectedEntries.formIntersection(Set(entries.map(\.id)))
            if let previewEntryID, !entries.contains(where: { $0.id == previewEntryID }) {
                let oldIndex = old.first(where: { $0.id == selectedID })?.entries.firstIndex(where: { $0.id == previewEntryID }) ?? 0
                self.previewEntryID = entries.isEmpty ? nil : entries[min(oldIndex, entries.count - 1)].id
            } else if previewEntryID == nil {
                resetPreview()
            }
        }
        .onChange(of: manager.currentEntryID) { old, new in
            // 自动播放时跟随当前项；用户浏览其他项时保留其预览位置。
            if manager.activeID == selectedID, previewEntryID == old || previewEntryID == nil {
                previewEntryID = new
            }
        }
        .onAppear {
            if selectedID == nil { selectedID = manager.activeID ?? manager.playlists.first?.id }
            resetPreview()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(selectedPlaylist?.name ?? "播放列表")
                    .font(.system(size: 23, weight: .semibold))
                    .lineLimit(1)
                Text(selectedPlaylist.map { "\($0.entries.count) 张壁纸" } ?? "我的壁纸合集")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Menu {
                ForEach(manager.playlists) { playlist in
                    Button {
                        selectedID = playlist.id
                    } label: {
                        if selectedID == playlist.id {
                            Label(playlist.name, systemImage: "checkmark")
                        } else {
                            Text(playlist.name)
                        }
                    }
                }
                if !manager.playlists.isEmpty { Divider() }
                Button("新建播放列表…", action: createPlaylist)
            } label: {
                Label("切换列表", systemImage: "list.bullet")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Menu {
                Button("新建播放列表…", action: createPlaylist)
                if let playlist = selectedPlaylist {
                    Button("重命名…") { rename(playlist) }
                    if manager.activeID == playlist.id {
                        Button("停止播放") { manager.stop() }
                    }
                    Divider()
                    Button("删除列表", role: .destructive) { manager.delete(playlist.id) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("管理播放列表")
        }
        .padding(.bottom, 18)
    }

    private func detail(for playlist: Playlist) -> some View {
        let isActive = manager.activeID == playlist.id
        let entry = playlist.entries.first { $0.id == previewEntryID } ?? playlist.entries.first
        return VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack(alignment: .bottomLeading) {
                    if let entry {
                        PlaylistLargePreview(entry: entry)
                        LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                            .allowsHitTesting(false)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.title)
                                .font(.system(size: 20, weight: .medium))
                                .lineLimit(1)
                            HStack(spacing: 8) {
                                Text(entry.kindLabel)
                                if let index = playlist.entries.firstIndex(where: { $0.id == entry.id }) {
                                    Text("\(index + 1) / \(playlist.entries.count)")
                                }
                                if isActive && manager.currentEntryID == entry.id {
                                    Label(manager.isPaused ? "已暂停" : "正在播放", systemImage: manager.isPaused ? "pause.fill" : "speaker.wave.2.fill")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                        }
                        .foregroundStyle(.white)
                        .padding(20)
                    } else {
                        emptyPreview
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(.black.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    playbackControls(playlist)
                    Spacer(minLength: 8)
                    playbackSettings(playlist)
                    addWallpaperMenu
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { playbackControls(playlist); Spacer(); addWallpaperMenu }
                    playbackSettings(playlist)
                }
            }
            .padding(.vertical, 16)

            Divider().opacity(0.5)
            filmstrip(playlist)
            HStack(spacing: 6) {
                Text("单击预览 · 双击播放 · 拖动排序 · ⌘ 点击多选")
                Spacer()
                if !selectedEntries.isEmpty {
                    Button("移除 \(selectedEntries.count) 项", role: .destructive) {
                        manager.remove(selectedEntries, from: playlist.id)
                        selectedEntries.removeAll()
                    }
                    .buttonStyle(.borderless)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var emptyPreview: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 32, weight: .light))
            Text("还没有壁纸").font(.headline)
            Text("从发现或资料库选择壁纸，右键添加到这个列表。")
                .font(.callout)
            addWallpaperMenu
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func playbackControls(_ playlist: Playlist) -> some View {
        let isActive = manager.activeID == playlist.id
        return HStack(spacing: 8) {
            Button { stepPreview(-1, in: playlist) } label: {
                Image(systemName: "backward.end.fill").frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("上一张")
            Button {
                if isActive {
                    manager.setPlaybackPaused(!manager.isPaused)
                } else {
                    manager.play(playlist.id, startAt: previewEntryID)
                }
            } label: {
                Label(isActive ? (manager.isPaused ? "继续播放" : "暂停播放") : "播放列表",
                      systemImage: isActive && !manager.isPaused ? "pause.fill" : "play.fill")
                    .frame(minWidth: 88)
            }
            .buttonStyle(.borderedProminent)
            Button { stepPreview(1, in: playlist) } label: {
                Image(systemName: "forward.end.fill").frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("下一张")
        }
        .disabled(playlist.entries.isEmpty)
    }

    private func playbackSettings(_ playlist: Playlist) -> some View {
        HStack(spacing: 12) {
            Picker("间隔", selection: Binding(
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
        }
        .controlSize(.small)
    }

    private var addWallpaperMenu: some View {
        Menu {
            Button("从发现选择…") { MainWindow.show(tab: .discover) }
            Button("从资料库选择…") { MainWindow.show(tab: .library) }
        } label: {
            Label("添加壁纸", systemImage: "plus")
        }
        .fixedSize()
    }

    private func filmstrip(_ playlist: Playlist) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(playlist.entries) { entry in
                        entryCard(entry, isCurrent: manager.activeID == playlist.id && manager.currentEntryID == entry.id)
                            .frame(width: 160)
                            .id(entry.id)
                            .onTapGesture(count: 2) {
                                previewEntryID = entry.id
                                manager.play(playlist.id, startAt: entry.id)
                            }
                            .onTapGesture {
                                previewEntryID = entry.id
                                if NSEvent.modifierFlags.contains(.command) {
                                    if !selectedEntries.insert(entry.id).inserted { selectedEntries.remove(entry.id) }
                                } else {
                                    selectedEntries = [entry.id]
                                }
                            }
                            .draggable(entry.id)
                            .dropDestination(for: String.self) { ids, _ in
                                guard let id = ids.first, ids.count == 1, id != entry.id,
                                      let source = playlist.entries.firstIndex(where: { $0.id == id }),
                                      let target = playlist.entries.firstIndex(where: { $0.id == entry.id }) else { return false }
                                manager.move(in: playlist.id, from: IndexSet(integer: source), to: target > source ? target + 1 : target)
                                return true
                            }
                            .contextMenu {
                                Button("从这里开始播放") { manager.play(playlist.id, startAt: entry.id) }
                                Divider()
                                Button("移除", role: .destructive) {
                                    manager.remove(selectedEntries.contains(entry.id) ? selectedEntries : [entry.id], from: playlist.id)
                                }
                            }
                    }
                    if playlist.entries.isEmpty {
                        Text("添加的壁纸会出现在这里")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(height: 112)
                    }
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 14)
            }
            .frame(height: 152)
            .onChange(of: previewEntryID) { _, newID in
                if let newID {
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(newID, anchor: .center) }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .onDeleteCommand {
                manager.remove(selectedEntries, from: playlist.id)
                selectedEntries.removeAll()
            }
        }
    }

    private func entryCard(_ entry: PlaylistEntry, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            KFImage(source: thumbnailSource(for: entry))
                .setProcessor(GIFPosterFrameProcessor(maxPixelSize: 480))
                .cancelOnDisappear(true)
                .placeholder { Color.secondary.opacity(0.12) }
                .resizable()
                .scaledToFill()
                .frame(width: 160, height: 90)
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if isCurrent {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption)
                            .padding(6)
                            .background(.regularMaterial, in: Circle())
                            .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(previewEntryID == entry.id ? Color.primary : (selectedEntries.contains(entry.id) ? Color.accentColor : .clear), lineWidth: 2)
                }
            Text(entry.title)
                .font(.caption)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .help(entry.title)
    }

    private func thumbnailSource(for entry: PlaylistEntry) -> Source? {
        if entry.kind == .local, let path = entry.path {
            let url = URL(fileURLWithPath: path)
            if MediaType.isVideo(url) { return .provider(AVAssetImageDataProvider(assetURL: url, seconds: 1)) }
        }
        return entry.thumbnailURL.map { $0.isFileURL ? .provider(LocalFileImageDataProvider(fileURL: $0)) : $0.convertToSource() }
    }

    private func resetPreview() {
        let playlist = selectedPlaylist
        previewEntryID = playlist?.entries.first(where: { manager.activeID == playlist?.id && $0.id == manager.currentEntryID })?.id ?? playlist?.entries.first?.id
    }

    private func stepPreview(_ offset: Int, in playlist: Playlist) {
        guard !playlist.entries.isEmpty else { return }
        if manager.activeID == playlist.id {
            if offset < 0 { manager.previous() } else { manager.next() }
            previewEntryID = manager.currentEntryID
        } else {
            let index = playlist.entries.firstIndex { $0.id == previewEntryID } ?? 0
            previewEntryID = playlist.entries[(index + offset + playlist.entries.count) % playlist.entries.count].id
        }
    }

    private func createPlaylist() {
        PlaylistNamePrompt.shared.present(title: "新建播放列表", name: "播放列表 \(manager.playlists.count + 1)", confirm: "创建") { name in
            selectedID = manager.create(name: name).id
        }
    }

    private func rename(_ playlist: Playlist) {
        PlaylistNamePrompt.shared.present(title: "重命名播放列表", name: playlist.name, confirm: "保存") { name in
            manager.rename(playlist.id, to: name)
        }
    }
}

/// 复用画廊的高清图片、视频和工坊渲染；预览不设置桌面壁纸。
private struct PlaylistLargePreview: View {
    let entry: PlaylistEntry
    @State private var item: GalleryItem?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            if let item {
                ImmersiveBackground(item: item)
            } else {
                Color.black.opacity(0.2)
            }
            if isLoading {
                ProgressView().controlSize(.small)
            } else if item == nil {
                Label("壁纸文件不可用", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: entry) {
            isLoading = true
            switch entry.kind {
            case .wallhaven:
                item = entry.wallhaven.map { GalleryItem(origin: .remote($0)) }
            case .local:
                if let path = entry.path, FileManager.default.fileExists(atPath: path) {
                    item = GalleryItem(origin: .local(LocalMediaItem(url: URL(fileURLWithPath: path), creationDate: .distantPast, fileSize: 0, source: .imported)))
                } else { item = nil }
            case .workshop:
                let path = entry.path
                let workshop = await Task.detached(priority: .userInitiated) {
                    path.flatMap { WorkshopItem.load(from: URL(fileURLWithPath: $0)) }
                }.value
                guard !Task.isCancelled else { return }
                item = workshop.map { GalleryItem(origin: .workshop($0)) }
            }
            isLoading = false
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
            Button(MenuText.compact(playlist.name)) { manager.add([entry], to: playlist.id) }
        }
        if !manager.playlists.isEmpty { Divider() }
        Button("新建播放列表…") {
            let openPlaylistWindow = openWindow
            PlaylistNamePrompt.shared.present(title: "新建播放列表", name: "播放列表 \(manager.playlists.count + 1)", confirm: "创建") { name in
                manager.create(name: name, entries: [entry])
                ToastCenter.shared.show("已创建「\(name)」", style: .success)
                openPlaylistWindow(id: PlaylistsWindow.id)
            }
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

/// 在稳定的窗口上显示命名 sheet，右键菜单关闭后也不会丢失弹窗。
private final class PlaylistNamePrompt: NSObject, NSTextFieldDelegate {
    static let shared = PlaylistNamePrompt()
    private var alert: NSAlert?
    private var input: NSTextField?

    func present(title: String, name: String, confirm: String, onSubmit: @escaping @MainActor (String) -> Void) {
        guard alert == nil, let window = NSApp.keyWindow ?? MainWindow.existingWindow else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        input.stringValue = name
        input.placeholderString = "播放列表名称"
        input.setAccessibilityLabel("播放列表名称")
        input.delegate = self
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        self.alert = alert
        self.input = input
        // 菜单命令先结束跟踪，再显示 sheet。
        RunLoop.main.perform {
            MainActor.assumeIsolated {
                guard window.attachedSheet == nil else {
                    self.alert = nil
                    self.input = nil
                    return
                }
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                alert.beginSheetModal(for: window) { response in
                    MainActor.assumeIsolated {
                        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.alert = nil
                        self.input = nil
                        if response == .alertFirstButtonReturn, !name.isEmpty { onSubmit(name) }
                    }
                }
                input.selectText(nil)
            }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        alert?.buttons.first?.isEnabled = !(input?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}
