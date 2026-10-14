import Foundation
import CoreGraphics
import Combine
import Testing
@testable import wallhaven

struct PlaylistEditingTests {
    @Test func shiftSelectionWorksInBothDirectionsAndCommandAddsToIt() {
        let ids = ["a", "b", "c", "d", "e"]
        #expect(PlaylistEditing.selection(ids: ids, clicked: "d", anchor: "b", current: [], shift: true, command: false) == ["b", "c", "d"])
        #expect(PlaylistEditing.selection(ids: ids, clicked: "a", anchor: "c", current: [], shift: true, command: false) == ["a", "b", "c"])
        #expect(PlaylistEditing.selection(ids: ids, clicked: "c", anchor: "b", current: ["e"], shift: true, command: true) == ["b", "c", "e"])
        #expect(PlaylistEditing.selection(ids: ids, clicked: "b", anchor: nil, current: ["b", "d"], shift: false, command: true) == ["d"])
    }

    @Test func groupMovesPreserveSourceOrderInBothDirections() {
        let ids = ["a", "b", "c", "d", "e"]
        #expect(PlaylistEditing.moving(ids: ids, selected: ["b", "d"], before: "a") == ["b", "d", "a", "c", "e"])
        #expect(PlaylistEditing.moving(ids: ids, selected: ["b", "d"], before: nil) == ["a", "c", "e", "b", "d"])
        #expect(PlaylistEditing.moving(ids: ids, selected: ["b", "c"], before: "b") == ids)
    }

    @Test func insertionSkipsTheDraggedGroup() {
        #expect(PlaylistEditing.insertionAnchor(ids: ["a", "b", "c", "d"], hovered: "b", after: true, selected: ["b", "c"]) == "d")
        #expect(PlaylistEditing.insertionAnchor(ids: ["a", "b"], hovered: "b", after: true, selected: ["a"]) == nil)
    }

    @Test func restorationPreservesNewEntriesAndAvoidsDuplicates() {
        #expect(PlaylistEditing.restoring(current: ["a", "d", "new"], original: ["a", "b", "c", "d"], removed: ["b", "c"]) == ["a", "b", "c", "d", "new"])
        #expect(PlaylistEditing.restoring(current: ["b", "new"], original: ["a", "b", "c"], removed: ["a", "b", "c"]) == ["a", "b", "c", "new"])
        #expect(PlaylistEditing.restoring(current: ["new"], original: ["a", "b"], removed: ["a", "b"]) == ["a", "b", "new"])
    }

    @Test @MainActor func removalAndRestorePersistWithoutReplacingLaterEdits() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("playlists.json")
        let manager = PlaylistManager(storageURL: file)
        func entry(_ name: String) throws -> PlaylistEntry {
            try #require(PlaylistEntry(GalleryItem(origin: .local(LocalMediaItem(url: folder.appendingPathComponent("\(name).jpg"), creationDate: .distantPast, fileSize: 0, source: .imported)))))
        }
        let original = try [entry("a"), entry("b"), entry("c"), entry("d")]
        let playlist = manager.create(name: "test", entries: original)
        let removal = PlaylistRemoval(playlistID: playlist.id, original: original, removedIDs: [original[1].id, original[2].id], previewID: original[1].id)
        manager.remove(removal.removedIDs, from: playlist.id)
        let new = try entry("new")
        manager.add([new], to: playlist.id)
        manager.restore(removal)
        #expect(manager.playlists.first?.entries.map(\.id) == (original + [new]).map(\.id))
        manager.moveEntries([original[1].id, original[2].id], in: playlist.id, before: nil)
        manager.flushPendingSave()
        let reloaded = PlaylistManager(storageURL: file)
        #expect(reloaded.playlists.first?.entries.map(\.id) == [original[0].id, original[3].id, new.id, original[1].id, original[2].id])
        manager.delete(playlist.id)
        manager.restore(removal)
        #expect(manager.playlists.isEmpty)
    }

    @Test @MainActor func dragPositionChoosesInsertionAndCopyTargets() {
        let source = UUID(), target = UUID()
        let state = PlaylistDragState()
        state.frames = [
            "viewport": CGRect(x: 0, y: 0, width: 400, height: 120),
            "a": CGRect(x: 0, y: 0, width: 100, height: 100),
            "b": CGRect(x: 110, y: 0, width: 100, height: 100),
            "c": CGRect(x: 220, y: 0, width: 100, height: 100),
            "list-\(target.uuidString)": CGRect(x: -120, y: 0, width: 100, height: 100)
        ]
        state.begin(PlaylistDragPayload(playlistID: source, ids: ["b"]))
        defer { state.end() }
        state.update(point: CGPoint(x: 20, y: 40), playlistID: source, ids: ["a", "b", "c"])
        #expect(state.insertionBeforeID == "a")
        state.update(point: CGPoint(x: 380, y: 40), playlistID: source, ids: ["a", "b", "c"])
        #expect(state.insertionBeforeID == nil)
        #expect(state.insertionPlaylistID == source)
        state.update(point: CGPoint(x: -80, y: 40), playlistID: source, ids: ["a", "b", "c"])
        #expect(state.sidebarTargetID == target)
        #expect(state.insertionPlaylistID == nil)
        state.update(point: CGPoint(x: 500, y: 500), playlistID: source, ids: ["a", "b", "c"])
        #expect(state.sidebarTargetID == nil && state.insertionPlaylistID == nil)
    }

    @Test @MainActor func pointerMovementWithinSameDropTargetDoesNotPublishPageChanges() {
        let source = UUID()
        let state = PlaylistDragState()
        state.frames = [
            "viewport": CGRect(x: 0, y: 0, width: 400, height: 120),
            "a": CGRect(x: 0, y: 0, width: 100, height: 100),
            "b": CGRect(x: 110, y: 0, width: 100, height: 100)
        ]
        state.begin(PlaylistDragPayload(playlistID: source, ids: ["b"]))
        defer { state.end() }
        state.update(point: CGPoint(x: 10, y: 40), playlistID: source, ids: ["a", "b"])
        var pageChanges = 0, pointerChanges = 0
        let pageSubscription = state.objectWillChange.sink { pageChanges += 1 }
        let pointerSubscription = state.pointer.objectWillChange.sink { pointerChanges += 1 }
        state.update(point: CGPoint(x: 20, y: 40), playlistID: source, ids: ["a", "b"])
        state.update(point: CGPoint(x: 30, y: 40), playlistID: source, ids: ["a", "b"])
        #expect(pageChanges == 0)
        #expect(pointerChanges == 2)
        state.update(point: CGPoint(x: 380, y: 40), playlistID: source, ids: ["a", "b"])
        #expect(pageChanges == 1)
        withExtendedLifetime((pageSubscription, pointerSubscription)) {}
    }

    @Test func dragPayloadRetainsSourceListAndAllSelectedIDs() {
        let payload = PlaylistDragPayload(playlistID: UUID(), ids: ["a", "b"])
        let restored = PlaylistDragPayload.decode(payload.text)
        #expect(restored?.playlistID == payload.playlistID)
        #expect(restored?.ids == ["a", "b"])
        #expect(PlaylistDragPayload.decode("an external filename") == nil)
    }
}
