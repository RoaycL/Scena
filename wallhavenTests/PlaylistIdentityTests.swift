import Foundation
import Testing
@testable import wallhaven

/// 在线壁纸加入播放列表后会下载到本地：发现页 / 收藏页里的那张和资料库里的本地文件是同一张壁纸，
/// 「已在列表中」的判断和防重复都要按壁纸本身，而不是条目 ID
@MainActor
@Suite(.serialized)
struct PlaylistIdentityTests {
    private func wallpaper(_ id: String) throws -> RemoteWallpaper {
        let data = Data("""
        {"id":"\(id)","url":"https://wallhaven.cc/w/\(id)","path":"https://example.com/\(id).jpg","resolution":"1920x1080","category":"general","favorites":1,"ratio":"1.777","purity":"sfw"}
        """.utf8)
        return try JSONDecoder().decode(RemoteWallpaper.self, from: data)
    }

    private func remoteEntry(_ id: String) throws -> PlaylistEntry {
        try #require(PlaylistEntry(GalleryItem(origin: .remote(wallpaper(id)))))
    }

    /// 资料库里看到的下载文件：和 DownloadService 一样存在下载目录里，以壁纸 ID 命名
    private func libraryEntry(_ id: String, folder: String? = nil, source: LocalMediaSource = .wallhaven) throws -> PlaylistEntry {
        let directory = folder ?? DownloadLocation.currentPath
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(id).jpg")
        let item = LocalMediaItem(url: url, creationDate: .distantPast, fileSize: 0, source: source)
        return try #require(PlaylistEntry(GalleryItem(origin: .local(item))))
    }

    /// 播放列表文件里已有这些条目（不经过加入时的自动下载）
    private func manager(entries: [PlaylistEntry], in folder: URL) throws -> (PlaylistManager, UUID) {
        let url = folder.appendingPathComponent("playlists.json")
        let list = Playlist(id: UUID(), name: "list", entries: entries)
        PlaylistPersistenceWriter(url: url).flush([list])
        return (PlaylistManager(storageURL: url), list.id)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func onlineWallpaperAndItsDownloadedFileAreTheSameWallpaper() throws {
        let remote = try remoteEntry("l8vp7y")
        let local = try libraryEntry("l8vp7y")
        #expect(remote.id != local.id)
        #expect(remote.identity == local.identity)
        // 导入的文件、其他位置的同名文件不是在线壁纸
        let elsewhere = try libraryEntry("l8vp7y", folder: "/tmp/somewhere", source: .imported)
        #expect(elsewhere.identity == elsewhere.id)
        #expect(elsewhere.identity != remote.identity)
        #expect(try libraryEntry("l8vp7z").identity != remote.identity)
    }

    @Test func downloadedFileIsAlreadyInThePlaylistItWasAddedToFromDiscovery() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let remote = try remoteEntry("l8vp7y")
        let (manager, id) = try manager(entries: [remote], in: folder)
        let local = try libraryEntry("l8vp7y")

        // 资料库里这张显示在列表中；再加一次不会重复
        #expect(manager.playlists[0].entries.contains { $0.identity == local.identity })
        manager.add([local], to: id)
        #expect(manager.playlists[0].entries.map(\.id) == [remote.id])
        // 从资料库取消勾选时，移除的是列表里实际存的那一条
        #expect(manager.entryIDs(matching: local.identity, in: id) == [remote.id])
        manager.remove(manager.entryIDs(matching: local.identity, in: id), from: id)
        #expect(manager.playlists[0].entries.isEmpty)
    }

    @Test func onlineWallpaperIsAlreadyInThePlaylistItsDownloadedFileWasAddedTo() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = try libraryEntry("l8vp7y")
        let (manager, id) = try manager(entries: [local], in: folder)
        let remote = try remoteEntry("l8vp7y")

        #expect(manager.playlists[0].entries.contains { $0.identity == remote.identity })
        manager.add([remote], to: id)
        #expect(manager.playlists[0].entries.map(\.id) == [local.id])
        #expect(manager.entryIDs(matching: remote.identity, in: id) == [local.id])
    }

    @Test func newPlaylistDropsDuplicateWallpapers() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = try libraryEntry("l8vp7y")
        let manager = PlaylistManager(storageURL: folder.appendingPathComponent("playlists.json"))
        let list = manager.create(name: "new", entries: [local, try remoteEntry("l8vp7y"), local])
        #expect(list.entries.map(\.id) == [local.id])
    }

    @Test func duplicatesKeepOneEntryPerWallpaperAndPreferTheOneThatIsPlaying() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try remoteEntry("l8vp7y"), aFile = try libraryEntry("l8vp7y")
        let b = try remoteEntry("abc123"), bFile = try libraryEntry("abc123"), bAgain = try libraryEntry("abc123")
        let c = try remoteEntry("zzz999")
        let (manager, id) = try manager(entries: [a, b, aFile, c, bFile, bAgain], in: folder)
        // 每张留最靠前的一条
        #expect(manager.duplicateEntryIDs(in: id) == [aFile.id, bFile.id])
        // 没有重复的列表什么也不动
        let cleanFolder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: cleanFolder) }
        let (clean, cleanID) = try self.manager(entries: [a, b, c], in: cleanFolder)
        #expect(clean.duplicateEntryIDs(in: cleanID).isEmpty)
        // 去除后每张只剩一条，其余顺序不变
        manager.remove(manager.duplicateEntryIDs(in: id), from: id)
        #expect(manager.playlists[0].entries.map(\.id) == [a.id, b.id, c.id])
        #expect(manager.duplicateEntryIDs(in: id).isEmpty)
    }
}
