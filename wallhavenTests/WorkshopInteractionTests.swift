import AppKit
import Foundation
import Testing
@testable import wallhaven

@MainActor
@Suite(.serialized)
struct WorkshopInteractionTests {
    private let testDefaults = TestDefaults()
    @Test func disabledConversionNeverSelectsCachedVideo() {
        var cacheReads = 0
        let cached = URL(fileURLWithPath: "/test/converted.mp4")
        let selected = WorkshopPlaybackPolicy.videoURL(original: nil, useConvertedVideo: false) {
            cacheReads += 1
            return cached
        }
        #expect(selected == nil && cacheReads == 0)
        #expect(WorkshopPlaybackPolicy.videoURL(original: nil, useConvertedVideo: true) { cached } == cached)
        #expect(WorkshopPlaybackPolicy.videoURL(original: nil, useConvertedVideo: true) { nil } == nil)
    }

    @Test(arguments: [true, false])
    func originalVideoAlwaysUsesItsSource(useConverted: Bool) {
        let original = URL(fileURLWithPath: "/test/source.mp4")
        var cacheReads = 0
        let selected = WorkshopPlaybackPolicy.videoURL(original: original, useConvertedVideo: useConverted) {
            cacheReads += 1
            return URL(fileURLWithPath: "/test/converted.mp4")
        }
        #expect(selected == original && cacheReads == 0)
    }

    @Test func desktopKeyboardFocusRequiresExplicitInteraction() {
        let window = WallpaperDesktopWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                                            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let desktop = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.setInteractionEnabled(false, desktopLevel: desktop)
        #expect(!window.canBecomeKey && !window.canBecomeMain)
        #expect(window.ignoresMouseEvents && !window.acceptsMouseMovedEvents && window.level == desktop)
        window.setInteractionEnabled(true, desktopLevel: desktop)
        #expect(window.canBecomeKey && !window.canBecomeMain)
        #expect(!window.ignoresMouseEvents && window.acceptsMouseMovedEvents && window.level == .normal)
        window.setInteractionEnabled(false, desktopLevel: desktop)
        #expect(!window.canBecomeKey)
        #expect(window.ignoresMouseEvents && !window.acceptsMouseMovedEvents && window.level == desktop)
    }

    @Test func webPlayerOnlyReceivesHitsInInteractionMode() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"type":"web","file":"index.html","title":"Test"}"#.utf8).write(to: folder.appendingPathComponent("project.json"))
        try Data("<html><button>Test</button></html>".utf8).write(to: folder.appendingPathComponent("index.html"))
        let item = try #require(WorkshopItem.load(from: folder, computeSize: false))
        let player = WorkshopPlayerNSView(item: item, storage: WorkshopWebStorage(scope: item.id, defaults: testDefaults.make(), directory: testDefaults.makeDirectory()))
        defer { player.stop() }
        player.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        player.layoutSubtreeIfNeeded()
        let point = NSPoint(x: 160, y: 100)
        #expect(player.hitTest(point) == nil)
        player.setInteractionEnabled(true)
        #expect(player.allowsInteraction)
        #expect(player.hitTest(point) != nil)
        player.setInteractionEnabled(false)
        #expect(player.hitTest(point) == nil)
        player.stop()
        player.setInteractionEnabled(true)
        #expect(!player.allowsInteraction && player.hitTest(point) == nil)
    }

    @Test func scenePlayerDoesNotBecomeAnInteractiveWebPage() {
        let item = WorkshopItem(id: "test", title: "Test", type: .scene, tags: [])
        let player = WorkshopPlayerNSView(item: item, storage: WorkshopWebStorage(scope: item.id, defaults: testDefaults.make(), directory: testDefaults.makeDirectory()))
        defer { player.stop() }
        player.setInteractionEnabled(true)
        #expect(!player.allowsInteraction)
    }
}
