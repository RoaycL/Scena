import AppKit
import Foundation
import Testing
@testable import wallhaven

@MainActor
struct WorkshopLibraryIndexTests {
    private func fixture() throws -> (URL, URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = folder.appendingPathComponent("library")
        let item = root.appendingPathComponent("12345")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try project(title: "original", at: item)
        try Data([1, 2, 3]).write(to: item.appendingPathComponent("video.mp4"))
        try Data([1]).write(to: item.appendingPathComponent("preview.jpg"))
        return (folder, root, item)
    }

    private func project(title: String, at folder: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: ["workshopid": "12345", "title": title, "type": "video",
            "file": "video.mp4", "preview": "preview.jpg", "tags": ["Nature"]])
        try data.write(to: folder.appendingPathComponent("project.json"), options: .atomic)
    }

    @Test func restartUsesPersistentMetadataWithoutReparsing() async throws {
        let (folder, root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let indexURL = folder.appendingPathComponent("index.json")
        let first = WorkshopLibraryIndex(url: indexURL)
        let initial = await first.scan(roots: [root])
        #expect(initial.count == 1 && initial[0].fileSize > 0)
        #expect(await first.statistics.parsedProjects == 1)
        let second = WorkshopLibraryIndex(url: indexURL)
        #expect(await second.cachedItems(roots: [root]) == initial)
        #expect(await second.scan(roots: [root]) == initial)
        #expect(await second.statistics.parsedProjects == 0)
        #expect(await second.statistics.reusedProjects == 1)
    }

    @Test func projectAndVideoReplacementInvalidateMetadata() async throws {
        let (folder, root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = WorkshopLibraryIndex(url: folder.appendingPathComponent("index.json"))
        _ = await index.scan(roots: [root])
        try project(title: "updated and longer", at: item)
        let updated = await index.scan(roots: [root])
        #expect(updated.first?.title == "updated and longer")
        let oldSize = try #require(updated.first?.fileSize)
        try Data(repeating: 1, count: 1000).write(to: item.appendingPathComponent("video.mp4"))
        let replaced = await index.scan(roots: [root])
        #expect(replaced.first?.fileSize == oldSize + 997)
        #expect(await index.statistics.parsedProjects == 1)
    }

    @Test func offlineRootPreservesIndexAndDeletedItemsAreRemovedAfterSuccessfulScan() async throws {
        let (folder, root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let indexURL = folder.appendingPathComponent("index.json")
        let index = WorkshopLibraryIndex(url: indexURL)
        let initial = await index.scan(roots: [root])
        let offline = folder.appendingPathComponent("offline")
        try FileManager.default.moveItem(at: root, to: offline)
        #expect(await index.scan(roots: [root]).isEmpty)
        #expect(await index.cachedItems(roots: [root]).isEmpty)
        let restarted = WorkshopLibraryIndex(url: indexURL)
        try FileManager.default.moveItem(at: offline, to: root)
        #expect(await restarted.cachedItems(roots: [root]) == initial)
        #expect(await restarted.scan(roots: [root]) == initial)
        try FileManager.default.removeItem(at: item)
        #expect(await restarted.scan(roots: [root]).isEmpty)
        #expect(await WorkshopLibraryIndex(url: indexURL).cachedItems(roots: [root]).isEmpty)
    }

    @Test func nestedChangesAreReconciledAndExplicitInvalidationIsImmediate() async throws {
        let (folder, root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let nested = item.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("data.bin")
        try Data([1]).write(to: file)
        let index = WorkshopLibraryIndex(url: folder.appendingPathComponent("index.json"))
        let start = Date()
        let initial = await index.scan(roots: [root], now: start)
        try Data(repeating: 1, count: 100).write(to: file)
        let reconciled = await index.scan(roots: [root], now: start.addingTimeInterval(86401))
        #expect(reconciled[0].fileSize == initial[0].fileSize + 99)
        try Data(repeating: 1, count: 200).write(to: file)
        await index.invalidate(folder: item)
        let invalidated = await index.scan(roots: [root], now: start.addingTimeInterval(86402))
        #expect(invalidated[0].fileSize == reconciled[0].fileSize + 100)
    }

    @Test func corruptIndexRebuildsAndSingleFolderRootsDeduplicate() async throws {
        let (folder, root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let indexURL = folder.appendingPathComponent("index.json")
        try Data("broken json".utf8).write(to: indexURL)
        let index = WorkshopLibraryIndex(url: indexURL)
        #expect(await index.cachedItems(roots: [root]).isEmpty)
        let scanned = await index.scan(roots: [root, item])
        #expect(scanned.count == 1 && scanned[0].title == "original")
        #expect(scanned[0].nativeVideoURL?.resolvingSymlinksInPath() == item.appendingPathComponent("video.mp4").resolvingSymlinksInPath())
    }

    @Test func hiddenPreviewWarmsFirstFrameButHonorsManualPause() {
        #expect(PreviewPlaybackPolicy.shouldPlay(wantsPlaying: true, isReady: false, isVisible: false))
        #expect(!PreviewPlaybackPolicy.shouldPlay(wantsPlaying: true, isReady: true, isVisible: false))
        #expect(PreviewPlaybackPolicy.shouldPlay(wantsPlaying: true, isReady: true, isVisible: true))
        #expect(!PreviewPlaybackPolicy.shouldPlay(wantsPlaying: false, isReady: false, isVisible: true))
        #expect(!PreviewPlaybackPolicy.shouldPlay(wantsPlaying: false, isReady: true, isVisible: true))
    }

    @Test func windowVisibilityChangesAndObserverDetaches() async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 16, height: 16),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.ignoresMouseEvents = true
        defer { window.orderOut(nil); window.close() }
        var visible = false
        var events = 0
        let observer = WindowVisibilityObserver { value in visible = value; events += 1 }
        observer.attach(to: window)
        #expect(!visible)
        window.orderFront(nil)
        for _ in 0..<100 {
            if visible { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(visible)
        window.orderOut(nil)
        for _ in 0..<100 {
            if !visible { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!visible)
        observer.stop()
        let before = events
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(events == before)
    }
}
