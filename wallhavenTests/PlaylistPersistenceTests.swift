import Foundation
import Testing
@testable import wallhaven

@MainActor
@Suite(.serialized)
struct PlaylistPersistenceTests {
    @Test func editsCoalesceAndEventuallySurviveReload() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("playlists.json")
        let manager = PlaylistManager(storageURL: url)
        let list = manager.create(name: "initial")
        manager.rename(list.id, to: "second")
        manager.setInterval(300, for: list.id)
        manager.rename(list.id, to: "final")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: url.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let reloaded = PlaylistManager(storageURL: url)
        #expect(reloaded.playlists.first?.name == "final")
        #expect(reloaded.playlists.first?.interval == 300)
    }

    @Test func flushCancelsDebounceAndCannotBeOverwrittenByQueuedOlderSave() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("playlists.json")
        let writer = PlaylistPersistenceWriter(url: url)
        let list = Playlist(id: UUID(), name: "old")
        for _ in 0..<20 { writer.enqueue([list]) }
        var latest = list
        latest.name = "latest"
        writer.flush([latest])
        #expect(PlaylistManager(storageURL: url).playlists.first?.name == "latest")
        let manager = PlaylistManager(storageURL: url)
        manager.rename(list.id, to: "pending")
        manager.rename(list.id, to: "exit")
        manager.flushPendingSave()
        #expect(PlaylistManager(storageURL: url).playlists.first?.name == "exit")
        try await Task.sleep(for: .milliseconds(400))
        #expect(PlaylistManager(storageURL: url).playlists.first?.name == "exit")
    }

    @Test func lightweightWorkshopLoadPreservesPlaybackMetadata() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("""
        {"workshopid":"12345","title":"fixture","type":"video","file":"clip.mp4","preview":"preview.jpg","tags":["Nature"],"contentrating":"Everyone"}
        """.utf8).write(to: folder.appendingPathComponent("project.json"))
        try Data(repeating: 0, count: 100).write(to: folder.appendingPathComponent("preview.jpg"))
        let full = try #require(WorkshopItem.load(from: folder))
        var lightweight = try #require(WorkshopItem.load(from: folder, computeSize: false))
        #expect(full.fileSize > 0 && lightweight.fileSize == 0)
        #expect(lightweight.nativeVideoURL == folder.appendingPathComponent("clip.mp4"))
        lightweight.fileSize = full.fileSize
        #expect(lightweight == full)
    }
}
