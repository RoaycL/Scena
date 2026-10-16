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
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedID: UUID?
    @State private var previewEntryID: String?
    @State private var selectedEntries = Set<String>()
    @State private var selectionAnchorID: String?
    @State private var removalHistory: [PlaylistRemoval] = []
    @State private var restoredSelection: PlaylistRemoval?
    @StateObject private var dragState = PlaylistDragState()
    /// 正在拖动排序的播放列表（侧栏分组）
    @State private var draggingPlaylistID: UUID?
    /// 按下点相对缩略图中心的偏移：拖动预览保持在手指抓住的位置，像直接拖着这张图
    @State private var dragGrabOffset = CGSize.zero
    @StateObject private var interactionInput = PlaylistInteractionInput()
    var embedded = false
    var panelWidth: CGFloat = 1180
    var maximumHeight: CGFloat = 820
    var onKeyboardHandler: (((ImmersiveWindowController.Key) -> Bool)?) -> Void = { _ in }
    @State private var displayedPreviewID: String?
    @State private var failedPreviewID: String?

    private var selectedPlaylist: Playlist? {
        manager.playlists.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if !manager.playlists.isEmpty {
                sidebar
                Divider()
                    .padding(.trailing, 24)
            }
            content
        }
        .padding(24)
        // 独立窗口没有沉浸式背景，铺一层原生磨砂（窗口本身是透明的）；嵌入主界面时由外层玻璃面板提供背景
        .background { if !embedded { ScenaWindowGlass().ignoresSafeArea() } }
        .coordinateSpace(name: "playlistBoard")
        .onPreferenceChange(PlaylistDragFramesKey.self) { frames in
            MainActor.assumeIsolated {
                dragState.frames = frames
                if dragState.payload != nil, let playlist = selectedPlaylist {
                    dragState.update(point: dragState.pointer.location, playlistID: playlist.id, ids: playlist.entries.map(\.id))
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if let payload = dragState.payload {
                PlaylistDragPreviewLayer(
                    pointer: dragState.pointer, payload: payload, grabOffset: dragGrabOffset,
                    entry: manager.playlists.first(where: { $0.id == payload.playlistID })?.entries.first(where: { $0.id == payload.ids.first }),
                    isCopying: dragState.sidebarTargetID != nil
                )
                    .allowsHitTesting(false)
                    .transition(Motion.reducesMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .frame(width: embedded ? panelWidth : nil, height: embedded ? maximumHeight : nil)
        .frame(minWidth: embedded ? nil : 900, minHeight: embedded ? nil : 560)
        .onChange(of: previewEntryID) { failedPreviewID = nil }
        .onChange(of: selectedID) {
            selectedEntries.removeAll()
            selectionAnchorID = nil
            dragState.end()
            if let restoredSelection, restoredSelection.playlistID == selectedID {
                selectedEntries = restoredSelection.removedIDs
                previewEntryID = restoredSelection.previewID
                selectionAnchorID = restoredSelection.previewID
                self.restoredSelection = nil
            } else { resetPreview() }
        }
        .onChange(of: manager.playlists) { old, new in
            // 移除正在预览的条目时选择原位置的下一张，避免队列回到开头。
            if let selectedID, !new.contains(where: { $0.id == selectedID }) {
                self.selectedID = manager.activeID ?? new.first?.id
                return
            }
            if selectedID == nil { selectedID = new.first?.id }
            let entries = selectedPlaylist?.entries ?? []
            selectedEntries.formIntersection(Set(entries.map(\.id)))
            if let selectionAnchorID, !entries.contains(where: { $0.id == selectionAnchorID }) { self.selectionAnchorID = nil }
            removalHistory.removeAll { removal in !new.contains { $0.id == removal.playlistID } }
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
        .onDisappear { onKeyboardHandler(nil); dragState.end(); interactionInput.stop() }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.space, .leftArrow, .rightArrow, .return]) { press in
            let key: ImmersiveWindowController.Key = switch press.key {
            case .space: .space
            case .leftArrow: .left
            case .rightArrow: .right
            default: .enter
            }
            return handleKeyboard(key) ? .handled : .ignored
        }
        .onAppear {
            interactionInput.start()
            onKeyboardHandler(handleKeyboard)
            if selectedID == nil { selectedID = manager.activeID ?? manager.playlists.first?.id }
            resetPreview()
        }
    }

    // MARK: - Sidebar

    /// 左侧列出所有播放列表：封面、名称、张数、播放状态，单击查看、双击播放
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("播放列表").font(.headline)
                Spacer()
                Text("\(manager.playlists.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)

            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(manager.playlists) { playlist in
                        PlaylistSidebarRow(
                            playlist: playlist,
                            isSelected: playlist.id == selectedID,
                            isActive: playlist.id == manager.activeID,
                            isPaused: manager.isPaused
                        )
                        .id(playlist.id)
                        // 拖动排序：拖起的行变淡，经过其他行时实时让位
                        .opacity(draggingPlaylistID == playlist.id ? 0.55 : 1)
                        .scaleEffect(draggingPlaylistID == playlist.id && !Motion.reducesMotion ? 1.02 : 1)
                        .animation(Motion.hover, value: draggingPlaylistID == playlist.id)
                        // 单击立即响应；双击另外识别（先写 count: 2 会让单击等待双击判定）
                        .onTapGesture { selectedID = playlist.id }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { manager.play(playlist.id) })
                        // 拖动排序：用自定义拖动手势（系统拖放 onDrag 会吞掉单击）。经过其他行时实时让位
                        .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("playlistBoard"))
                            .onChanged { value in reorderPlaylist(playlist.id, at: value.location) }
                            .onEnded { _ in draggingPlaylistID = nil })
                        // 把下方队列里的壁纸拖到其他列表上：复制过去
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.card)
                                .stroke(dragState.sidebarTargetID == playlist.id ? Color.accentColor : .clear, lineWidth: 2)
                        }
                        .playlistDragFrame("list-\(playlist.id.uuidString)")
                        .contextMenu {
                            if manager.activeID == playlist.id {
                                Button(manager.isPaused ? "继续播放" : "暂停播放") { manager.setPlaybackPaused(!manager.isPaused) }
                                Button("停止播放") { manager.stop() }
                            } else {
                                Button("播放") { manager.play(playlist.id) }
                                    .disabled(playlist.entries.isEmpty)
                            }
                            Divider()
                            Button("重命名…") { rename(playlist) }
                            Button("删除列表", role: .destructive) { manager.delete(playlist.id) }
                        }
                    }
                }
            }
            // 鼠标滚轮 / 触控板在侧栏上滚动：切换上一个、下一个播放列表
            .background(ScrollWheelSwitcher { step in
                let ids = manager.playlists.map(\.id)
                guard !ids.isEmpty else { return }
                let index = selectedID.flatMap { ids.firstIndex(of: $0) } ?? 0
                let next = ids[min(max(index + step, 0), ids.count - 1)]
                guard next != selectedID else { return }
                withAnimation(Motion.hover) { selectedID = next }
                withAnimation(Motion.scroll) { proxy.scrollTo(next) }
            })
            }

            Divider().padding(.vertical, 8)
            Button(action: createPlaylist) {
                Label("新建播放列表", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
        }
        .frame(width: 236)
        .padding(.trailing, 16)
    }

    /// 拖动中的列表经过哪一行，就移到那一行的位置（行的位置来自 playlistDragFrame 记录的 list-<id>）
    private func reorderPlaylist(_ id: UUID, at point: CGPoint) {
        if draggingPlaylistID != id { draggingPlaylistID = id }
        guard let target = manager.playlists.first(where: { other in
            guard other.id != id, let frame = dragState.frames["list-\(other.id.uuidString)"] else { return false }
            return point.y >= frame.minY && point.y <= frame.maxY
        }) else { return }
        withAnimation(Motion.hover) { manager.movePlaylist(id, to: target.id) }
    }

    private func copyEntries(_ payload: PlaylistDragPayload, to target: Playlist) -> Bool {
        guard let source = manager.playlists.first(where: { $0.id == payload.playlistID }), source.id != target.id else { return false }
        let entries = source.entries.filter { payload.ids.contains($0.id) }
        guard !entries.isEmpty else { return false }
        manager.add(entries, to: target.id)
        ToastCenter.shared.show("已添加 \(entries.count) 张到「\(target.name)」", style: .success)
        return true
    }

    private func selectEntry(_ id: String, in playlist: Playlist) {
        let flags = interactionInput.clickModifiers
        let shift = flags.contains(.shift), command = flags.contains(.command)
        selectedEntries = PlaylistEditing.selection(ids: playlist.entries.map(\.id), clicked: id,
            anchor: selectionAnchorID ?? previewEntryID, current: selectedEntries, shift: shift, command: command)
        if !shift { selectionAnchorID = id }
        previewEntryID = id
    }

    private func removeEntries(_ ids: Set<String>, from playlist: Playlist) {
        let removed = ids.intersection(Set(playlist.entries.map(\.id)))
        guard !removed.isEmpty else { return }
        removalHistory.append(PlaylistRemoval(playlistID: playlist.id, original: playlist.entries, removedIDs: removed, previewID: previewEntryID))
        manager.remove(removed, from: playlist.id)
        selectedEntries.subtract(removed)
    }

    private func undoRemoval() {
        // 命名 sheet 等输入框的 ⌘Z 仍交给文本编辑器。
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            editor.undoManager?.undo()
            return
        }
        guard let removal = removalHistory.popLast() else { return }
        manager.restore(removal)
        if selectedID != removal.playlistID { restoredSelection = removal }
        selectedID = removal.playlistID
        selectedEntries = removal.removedIDs
        previewEntryID = removal.previewID
        selectionAnchorID = removal.previewID
    }

    @ViewBuilder
    private var content: some View {
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
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(selectedPlaylist?.name ?? "播放列表")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text(selectedPlaylist.map { "\($0.entries.count) 张壁纸 · 拖到左侧其他列表可复制" } ?? "我的壁纸合集")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
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
                        PlaylistLargePreview(entry: entry, onDisplayed: { displayedPreviewID = $0; failedPreviewID = nil }, onFailed: { failedPreviewID = $0 })
                            // 预览只负责显示。视频、动态壁纸等内容的布局可能超出可见区域，参与点击命中会挡住旁边的侧栏
                            .allowsHitTesting(false)
                        LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                            .allowsHitTesting(false)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(failedPreviewID == entry.id ? entry.title : (playlist.entries.first(where: { $0.id == displayedPreviewID })?.title ?? "加载中…"))
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                            HStack(spacing: 8) {
                                Text(failedPreviewID == entry.id ? "加载失败" : (displayedPreviewID == entry.id ? entry.kindLabel : "加载中…"))
                                if let index = playlist.entries.firstIndex(where: { $0.id == displayedPreviewID }) {
                                    Text("\(index + 1) / \(playlist.entries.count)")
                                }
                                if isActive && manager.currentEntryID == displayedPreviewID {
                                    Label { Text(manager.isPaused ? "已暂停" : "正在桌面播放") } icon: { PlaybackStateIcon(isPaused: manager.isPaused) }
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
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
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
                Text("拖动排序 · ⌘ 多选 · ⇧ 连续选择")
                Spacer()
                if !removalHistory.isEmpty {
                    Button("撤销移除", action: undoRemoval)
                        .keyboardShortcut("z", modifiers: .command)
                        .buttonStyle(.borderless)
                        .help("撤销最近一次移除（⌘Z）")
                }
                if !selectedEntries.isEmpty {
                    Button("移除 \(selectedEntries.count) 项", role: .destructive) {
                        removeEntries(selectedEntries, from: playlist)
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
                .font(.system(size: 34, weight: .light))
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
                let title = isActive ? (manager.isPaused ? "继续播放" : "暂停播放") : "播放列表"
                let symbol = isActive && !manager.isPaused ? "pause.fill" : "play.fill"
                if embedded {
                    // 主界面里和「设为壁纸」同一种白色主按钮，不用系统蓝色按钮
                    HStack(spacing: 6) {
                        Image(systemName: symbol).contentTransition(.symbolEffect(.replace))
                        Text(title)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ThemePalette(scheme: colorScheme).primaryText)
                    .frame(minWidth: 88)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(ThemePalette(scheme: colorScheme).primaryFill, in: Capsule())
                    .animation(Motion.hover, value: symbol)
                } else {
                    Label(title, systemImage: symbol).frame(minWidth: 88)
                }
            }
            .modifier(PlayButtonStyle(embedded: embedded))
            Button { stepPreview(1, in: playlist) } label: {
                Image(systemName: "forward.end.fill").frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("下一张")
        }
        .disabled(playlist.entries.isEmpty)
    }

    @ViewBuilder
    private func playbackSettings(_ playlist: Playlist) -> some View {
        if embedded {
            // 主界面里：间隔和随机播放用玻璃胶囊，和筛选面板的选项同一套样式
            HStack(spacing: 8) {
                Menu {
                    ForEach(Playlist.intervals, id: \.seconds) { option in
                        Toggle(option.label, isOn: Binding(
                            get: { playlist.interval == option.seconds },
                            set: { if $0 { manager.setInterval(option.seconds, for: playlist.id) } }
                        ))
                    }
                } label: {
                    GlassChipLabel(systemImage: "timer",
                                   title: Playlist.intervals.first { $0.seconds == playlist.interval }?.label ?? "间隔",
                                   showsChevron: true)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("切换间隔")
                GlassChip(title: "随机播放", isOn: playlist.shuffle) {
                    manager.setShuffle(!playlist.shuffle, for: playlist.id)
                }
            }
        } else {
            nativePlaybackSettings(playlist)
        }
    }

    private func nativePlaybackSettings(_ playlist: Playlist) -> some View {
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
            if embedded {
                GlassChipLabel(systemImage: "plus", title: "添加壁纸")
            } else {
                Label("添加壁纸", systemImage: "plus")
            }
        }
        .modifier(GlassMenuStyle(embedded: embedded))
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
                            .onTapGesture { selectEntry(entry.id, in: playlist) }
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                previewEntryID = entry.id
                                manager.play(playlist.id, startAt: entry.id)
                            })
                            // 被拖起的卡片：微微缩小、变淡，像从队列里「提」了起来
                            .scaleEffect(!Motion.reducesMotion && dragState.payload?.ids.contains(entry.id) == true ? 0.94 : 1)
                            .opacity(dragState.payload?.ids.contains(entry.id) == true ? 0.45 : 1)
                            .animation(Motion.hover, value: dragState.payload?.ids.contains(entry.id) == true)
                            .overlay(alignment: .leading) {
                                if dragState.insertionPlaylistID == playlist.id && dragState.insertionBeforeID == entry.id {
                                    Capsule().fill(Color.accentColor).frame(width: 3, height: 96).offset(x: -7)
                                }
                            }
                            .playlistDragFrame(entry.id)
                            .simultaneousGesture(DragGesture(minimumDistance: 5, coordinateSpace: .named("playlistBoard"))
                                .onChanged { value in
                                    guard !dragState.isCancelled else { return }
                                    if dragState.payload == nil {
                                        let selected = selectedEntries.contains(entry.id) ? selectedEntries : [entry.id]
                                        if let frame = dragState.frames[entry.id] {
                                            dragGrabOffset = CGSize(width: frame.midX - value.startLocation.x,
                                                                    height: frame.minY + 45 - value.startLocation.y)
                                        }
                                        withAnimation(Motion.hover) {
                                            dragState.begin(PlaylistDragPayload(playlistID: playlist.id,
                                                ids: playlist.entries.map(\.id).filter { selected.contains($0) }))
                                        }
                                    }
                                    dragState.update(point: value.location, playlistID: playlist.id, ids: playlist.entries.map(\.id))
                                }
                                .onEnded { value in
                                    guard !dragState.isCancelled else { dragState.end(); return }
                                    dragState.update(point: value.location, playlistID: playlist.id, ids: playlist.entries.map(\.id))
                                    guard let payload = dragState.payload else { return }
                                    if let targetID = dragState.sidebarTargetID,
                                       let target = manager.playlists.first(where: { $0.id == targetID }) {
                                        _ = copyEntries(payload, to: target)
                                    } else if dragState.insertionPlaylistID == playlist.id {
                                        withAnimation(Motion.hover) {
                                            manager.moveEntries(Set(payload.ids), in: playlist.id, before: dragState.insertionBeforeID)
                                        }
                                    }
                                    dragState.end()
                                })
                            .contextMenu {
                                Button("从这里开始播放") { manager.play(playlist.id, startAt: entry.id) }
                                Divider()
                                Button("移除", role: .destructive) {
                                    removeEntries(selectedEntries.contains(entry.id) ? selectedEntries : [entry.id], from: playlist)
                                }
                            }
                    }
                    if !playlist.entries.isEmpty {
                        Color.clear.frame(width: 30, height: 112)
                            .overlay(alignment: .leading) {
                                if dragState.insertionPlaylistID == playlist.id && dragState.insertionBeforeID == nil {
                                    Capsule().fill(Color.accentColor).frame(width: 3, height: 96)
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
                .background(PlaylistScrollAccessor(onResolve: dragState.attach))
            }
            .frame(height: 152)
            .playlistDragFrame("viewport")
            .onChange(of: previewEntryID) { _, newID in
                if let newID {
                    withAnimation(Motion.scroll) { proxy.scrollTo(newID) }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .onDeleteCommand {
                removeEntries(selectedEntries, from: playlist)
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
                        PlaybackStateIcon(isPaused: manager.isPaused)
                            .font(.caption)
                            .padding(6)
                            .background(.regularMaterial, in: Circle())
                            .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.card)
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
        Self.thumbnailSource(for: entry)
    }

    static func thumbnailSource(for entry: PlaylistEntry) -> Source? {
        if entry.kind == .local, let path = entry.path {
            let url = URL(fileURLWithPath: path)
            if MediaType.isVideo(url) { return .provider(VideoPosterProvider(url: url, tier: .list)) }
        }
        return entry.thumbnailURL.map { $0.isFileURL ? .provider(LocalFileImageDataProvider(fileURL: $0)) : $0.convertToSource() }
    }

    private func handleKeyboard(_ key: ImmersiveWindowController.Key) -> Bool {
        if key == .escape, dragState.payload != nil { dragState.cancel(); return true }
        guard let playlist = selectedPlaylist, !playlist.entries.isEmpty else { return false }
        switch key {
        case .left, .right:
            let index = playlist.entries.firstIndex { $0.id == previewEntryID } ?? 0
            let offset = key == .left ? -1 : 1
            previewEntryID = playlist.entries[(index + offset + playlist.entries.count) % playlist.entries.count].id
            if let previewEntryID {
                if NSEvent.modifierFlags.contains(.shift) {
                    selectedEntries = PlaylistEditing.selection(ids: playlist.entries.map(\.id), clicked: previewEntryID,
                        anchor: selectionAnchorID ?? playlist.entries[index].id, current: selectedEntries, shift: true,
                        command: NSEvent.modifierFlags.contains(.command))
                    if selectionAnchorID == nil { selectionAnchorID = playlist.entries[index].id }
                } else { selectedEntries = [previewEntryID]; selectionAnchorID = previewEntryID }
            }
        case .space:
            if manager.activeID == playlist.id { manager.setPlaybackPaused(!manager.isPaused) }
            else { manager.play(playlist.id, startAt: previewEntryID) }
        case .enter:
            manager.play(playlist.id, startAt: previewEntryID)
        default: return false
        }
        return true
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
/// 侧栏里的一行：2×2 拼图封面 + 名称 + 张数 / 间隔 + 播放状态
private struct PlaylistSidebarRow: View {
    let playlist: Playlist
    let isSelected: Bool
    let isActive: Bool
    let isPaused: Bool
    @State private var isHovered = false

    private var intervalLabel: String {
        Playlist.intervals.first { $0.seconds == playlist.interval }?.label ?? ""
    }

    var body: some View {
        HStack(spacing: 10) {
            PlaylistCover(entries: Array(playlist.entries.prefix(4)))
                .frame(width: 68, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Text("\(playlist.entries.count) 张 · \(intervalLabel)\(playlist.shuffle ? " · 随机" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isActive {
                PlaybackStateIcon(isPaused: isPaused)
                    .font(.system(size: 13))
                    .foregroundStyle(isPaused ? Color.secondary : Color.accentColor)
                    .help(isPaused ? "已暂停" : "正在桌面轮播")
            }
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : (isHovered ? Color.primary.opacity(0.06) : .clear))
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help("单击查看 · 双击播放 · 拖动排序 · 滚动切换")
    }
}

/// 列表封面：最多 4 张壁纸拼成 2×2，不足时用第一张铺满
private struct PlaylistCover: View {
    let entries: [PlaylistEntry]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Group {
                if entries.count >= 4 {
                    VStack(spacing: 1) {
                        HStack(spacing: 1) { tile(entries[0]); tile(entries[1]) }
                        HStack(spacing: 1) { tile(entries[2]); tile(entries[3]) }
                    }
                } else if let first = entries.first {
                    tile(first)
                } else {
                    ZStack {
                        Color.secondary.opacity(0.15)
                        Image(systemName: "photo.stack").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private func tile(_ entry: PlaylistEntry) -> some View {
        KFImage(source: PlaylistsView.thumbnailSource(for: entry))
            .setProcessor(GIFPosterFrameProcessor(maxPixelSize: 200))
            .cancelOnDisappear(true)
            .placeholder { Color.secondary.opacity(0.15) }
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }
}

private struct PlaylistLargePreview: View {
    let entry: PlaylistEntry
    var onDisplayed: (String) -> Void
    var onFailed: (String) -> Void
    @State private var item: GalleryItem?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            // 先显示缩略图，大图或视频首帧就绪后再淡入，不会先黑一下
            KFImage(source: PlaylistsView.thumbnailSource(for: entry))
                .setProcessor(GIFPosterFrameProcessor(maxPixelSize: 480))
                .placeholder { Color.black.opacity(0.2) }
                .resizable()
                .scaledToFill()
                // 布局尺寸跟随预览区域，不被铺满后的图片撑大（否则上层的视频视图也会跟着变大）
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blur(radius: 6)
                .clipped()
            if let item {
                ImmersiveBackground(item: item, showsBlackBase: false, onDisplayed: { displayed in
                    let matches: Bool = switch (entry.kind, displayed.origin) {
                    case (.remote, .remote(let wallpaper)): wallpaper.id == entry.remote?.id
                    case (.local, .local(let local)): local.url.path == entry.path
                    case (.workshop, .workshop(let workshop)): workshop.localFolder?.path == entry.path
                    default: false
                    }
                    if matches { onDisplayed(entry.id) }
                }, onFailed: { failed in
                    let matches: Bool = switch (entry.kind, failed.origin) {
                    case (.remote, .remote(let wallpaper)): wallpaper.id == entry.remote?.id
                    case (.local, .local(let local)): local.url.path == entry.path
                    case (.workshop, .workshop(let workshop)): workshop.localFolder?.path == entry.path
                    default: false
                    }
                    guard matches else { return }
                    onFailed(entry.id)
                })
            }
            if isLoading && item == nil {
                ProgressView().controlSize(.small)
            } else if item == nil {
                Label("壁纸文件不可用", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: entry) {
            isLoading = true
            switch entry.kind {
            case .remote:
                item = entry.remote.map { GalleryItem(origin: .remote($0)) }
            case .local:
                if let path = entry.path, FileManager.default.fileExists(atPath: path) {
                    item = GalleryItem(origin: .local(LocalMediaItem(url: URL(fileURLWithPath: path), creationDate: .distantPast, fileSize: 0, source: .imported)))
                } else { item = nil }
            case .workshop:
                let path = entry.path
                let workshop = await Task.detached(priority: .userInitiated) {
                    path.flatMap { WorkshopItem.load(from: URL(fileURLWithPath: $0), computeSize: false) }
                }.value
                guard !Task.isCancelled else { return }
                item = workshop.map { GalleryItem(origin: .workshop($0)) }
            }
            isLoading = false
            if item == nil { onFailed(entry.id) }
        }
    }
}

/// 「添加到播放列表」的菜单项：各个播放列表 + 新建
struct AddToPlaylistItems: View {
    @ObservedObject private var manager = PlaylistManager.shared
    @Environment(\.openWindow) private var openWindow
    let entry: PlaylistEntry

    var body: some View {
        // 已经包含这张壁纸的列表打勾；再点一次从该列表移除
        ForEach(manager.playlists) { playlist in
            Toggle(MenuText.compact(playlist.name), isOn: Binding(
                get: { playlist.entries.contains { $0.id == entry.id } },
                set: { add in
                    if add {
                        manager.add([entry], to: playlist.id)
                    } else {
                        manager.remove([entry.id], from: playlist.id)
                        ToastCenter.shared.show("已从「\(playlist.name)」移除", style: .info)
                    }
                }
            ))
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

/// 未下载的工坊壁纸：先下载，完成后加入选择的播放列表
struct DownloadThenAddToPlaylistItems: View {
    @ObservedObject private var manager = PlaylistManager.shared
    @EnvironmentObject private var workshop: WorkshopViewModel
    let item: WorkshopItem

    var body: some View {
        ForEach(manager.playlists) { playlist in
            Button(MenuText.compact(playlist.name)) {
                workshop.downloadAndAddToPlaylist(item, playlistID: playlist.id)
            }
        }
        if !manager.playlists.isEmpty { Divider() }
        Button("新建播放列表…") {
            PlaylistNamePrompt.shared.present(title: "新建播放列表", name: "播放列表 \(manager.playlists.count + 1)", confirm: "创建") { name in
                let playlist = manager.create(name: name)
                workshop.downloadAndAddToPlaylist(item, playlistID: playlist.id)
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
        } else if let workshopItem = item.workshop, workshopItem.type.isPlayable {
            Menu("下载并添加到播放列表") {
                DownloadThenAddToPlaylistItems(item: workshopItem)
            }
        }
    }
}

/// 信息面板 / 详情栏里的「添加到播放列表」圆形按钮
struct AddToPlaylistButton: View {
    @ObservedObject private var manager = PlaylistManager.shared
    let item: GalleryItem
    @State private var burst = 0

    /// 已经在任意一个播放列表里：图标换成带对勾的样式
    private var isInPlaylist: Bool {
        guard let id = PlaylistEntry(item)?.id else { return false }
        return manager.playlists.contains { $0.entries.contains { $0.id == id } }
    }

    var body: some View {
        let isInPlaylist = isInPlaylist
        Menu {
            if let entry = PlaylistEntry(item) {
                AddToPlaylistItems(entry: entry)
            } else if let workshopItem = item.workshop, workshopItem.type.isPlayable {
                Section("下载完成后加入") {
                    DownloadThenAddToPlaylistItems(item: workshopItem)
                }
            }
        } label: {
            CircleIconLabel(systemImage: isInPlaylist ? "text.badge.checkmark" : "text.badge.plus",
                            tint: isInPlaylist ? .accentColor : .primary)
                .overlay { StateBurst(trigger: burst, color: .accentColor) }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(isInPlaylist ? "已在播放列表中（点击管理）" : "添加到播放列表")
        .onChange(of: isInPlaylist) { _, now in if now { burst += 1 } }
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


/// 只有浮图订阅鼠标位置；整页只响应插入位置和复制目标的变化。
private struct PlaylistDragPreviewLayer: View {
    @ObservedObject var pointer: PlaylistDragPointer
    let payload: PlaylistDragPayload
    let grabOffset: CGSize
    let entry: PlaylistEntry?
    let isCopying: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        ZStack {
            ForEach(Array(1..<min(payload.ids.count, 3)).reversed(), id: \.self) { depth in
                shape.fill(Color(white: 0.22))
                    .overlay(shape.stroke(.white.opacity(0.15), lineWidth: 0.5))
                    .frame(width: 160, height: 90)
                    .rotationEffect(.degrees(Motion.reducesMotion ? 0 : Double(depth) * 4))
                    .offset(x: CGFloat(depth) * 5, y: CGFloat(depth) * -3)
            }
            KFImage(source: entry.flatMap { PlaylistsView.thumbnailSource(for: $0) })
                .setProcessor(GIFPosterFrameProcessor(maxPixelSize: 480))
                .placeholder { Color(white: 0.22) }
                .resizable()
                .scaledToFill()
                .frame(width: 160, height: 90)
                .clipShape(shape)
                .overlay(shape.stroke(.white.opacity(0.25), lineWidth: 0.5))
        }
        .overlay(alignment: .topTrailing) {
            if payload.ids.count > 1 || isCopying {
                HStack(spacing: 3) {
                    if isCopying { Image(systemName: "plus") }
                    if payload.ids.count > 1 { Text("\(payload.ids.count)") }
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(isCopying ? Color.green : Color.accentColor, in: Capsule())
                .offset(x: 8, y: -8)
            }
        }
        // 拿起来的样子：略微放大、倾斜，投下较深的阴影
        .scaleEffect(Motion.reducesMotion ? 1 : (isCopying ? 0.8 : 1.04))
        .rotationEffect(.degrees(Motion.reducesMotion ? 0 : -2))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 10)
        .animation(Motion.hover, value: isCopying)
        .position(x: pointer.location.x + grabOffset.width, y: pointer.location.y + grabOffset.height)
    }
}

/// 主界面里的播放按钮用自定义白色胶囊；独立窗口跟随系统外观，保留系统按钮
private struct PlayButtonStyle: ViewModifier {
    let embedded: Bool
    func body(content: Content) -> some View {
        if embedded { content.buttonStyle(PressableButtonStyle()) } else { content.buttonStyle(.borderedProminent) }
    }
}

/// 主界面里的菜单去掉系统按钮外观，只显示玻璃胶囊标签
private struct GlassMenuStyle: ViewModifier {
    let embedded: Bool
    func body(content: Content) -> some View {
        if embedded {
            content.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        } else {
            content
        }
    }
}

/// 玻璃胶囊标签：图标 + 文字（可带下拉箭头），样式同 GlassChip 未选中态
struct GlassChipLabel: View {
    let systemImage: String
    let title: String
    var showsChevron = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
            }
        }
        .foregroundStyle(.primary.opacity(0.85))
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .overlay(Capsule().stroke(.primary.opacity(0.12), lineWidth: 0.5))
        .contentShape(Capsule())
    }
}

/// 播放列表正在桌面轮播的标识：「画面 + 播放」而不是声音图标；播放时轻轻呼吸，暂停时静止
struct PlaybackStateIcon: View {
    let isPaused: Bool

    var body: some View {
        Image(systemName: isPaused ? "pause.rectangle.fill" : "play.rectangle.fill")
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.pulse, options: .repeating, isActive: !isPaused && !Motion.reducesMotion)
    }
}

/// 在所在区域上滚动鼠标滚轮或触控板时回调 ±1。触控板按累计距离触发，惯性滚动不触发，避免一甩跳好几个
private struct ScrollWheelSwitcher: NSViewRepresentable {
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> Probe { Probe(onStep: onStep) }
    func updateNSView(_ view: Probe, context: Context) { view.onStep = onStep }

    final class Probe: NSView {
        var onStep: (Int) -> Void
        private var monitor: Any?
        private var accumulated: CGFloat = 0

        init(onStep: @escaping (Int) -> Void) {
            self.onStep = onStep
            super.init(frame: .zero)
        }

        /// 只用来确定区域、监听滚轮，不能接收点击：垫在列表下面的 AppKit 视图在命中测试里
        /// 会排在 SwiftUI 绘制的行前面，不返回 nil 就会把行上的单击全部截走
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.convert(self.bounds, to: nil).contains(event.locationInWindow) else { return event }
                return self.handle(event) ? nil : event
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            // 惯性阶段直接吞掉，不再切换
            guard event.momentumPhase.isEmpty else { return true }
            if event.phase == .began { accumulated = 0 }
            let delta = event.scrollingDeltaY
            guard abs(delta) > abs(event.scrollingDeltaX) else { return false }
            if event.hasPreciseScrollingDeltas {
                accumulated += delta
                guard abs(accumulated) >= 36 else { return true }
                let step = accumulated > 0 ? -1 : 1
                accumulated = 0
                onStep(step)
            } else if delta != 0 {
                // 鼠标滚轮：每一格切换一个
                onStep(delta > 0 ? -1 : 1)
            }
            return true
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
