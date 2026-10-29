import AppKit
import Foundation
import Testing
import WebKit
@testable import wallhaven

@MainActor
@Suite(.serialized)
struct WorkshopWebRuntimeTests {
    private let testDefaults = TestDefaults()

    @Test func sandboxedPageCanInitializeBindButtonsAndRestoreScopedStorage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"type":"web","file":"index.html","title":"Storage regression"}"#.utf8).write(to: folder.appendingPathComponent("project.json"))
        let html = """
        <!doctype html><html><body><button id="play">Play</button>
        <div id="cover" style="opacity:1;transition:opacity 120ms linear">Still cover</div><script>
        const storage = localStorage;
        window.started = true;
        window.pauseNotifications = [];
        window.wallpaperPropertyListener = {setPaused(value) { window.pauseNotifications.push(value); }};
        window.count = Number(storage.getItem('count') || '0');
        document.getElementById('play').addEventListener('click', () => {
          window.count++; storage.setItem('count', String(window.count));
        });
        </script></body></html>
        """
        try html.write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let defaults = testDefaults.make()
        let storage = WorkshopWebStorage(scope: "first", defaults: defaults)
        let item = try #require(WorkshopItem.load(from: folder, computeSize: false))
        let player = WorkshopPlayerNSView(item: item, storage: storage)
        let window = WallpaperDesktopWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = player
        window.orderFront(nil)
        defer { player.stop(); window.orderOut(nil); window.contentView = nil; window.close() }
        var frame: WKFrameInfo?
        for _ in 0..<200 {
            for candidate in player.documentFrames where !candidate.isMainFrame {
                if (try? await player.evaluateJavaScript("window.started === true", in: candidate)) as? Bool == true {
                    frame = candidate; break
                }
            }
            if frame != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let diagnostic = try? await player.evaluateJavaScript("JSON.stringify({url:location.href,html:document.documentElement.outerHTML.slice(-1800),bridge:typeof window.__scenaHostVisibility,frames:document.querySelectorAll('iframe').length})")
        let loaded = try #require(frame, "Page failed to initialize: \(player.runtimeErrors), state: \(player.state), frames: \(player.documentFrames.count), diagnostic: \(String(describing: diagnostic))")
        #expect((try await player.evaluateJavaScript("typeof window.__weSetPaused", in: loaded)) as? String == "function")
        #expect((try await player.evaluateJavaScript("document.querySelector('iframe').getAttribute('sandbox')")) as? String == "allow-scripts")
        _ = try await player.evaluateJavaScript("document.getElementById('play').click()", in: loaded)
        #expect((try await player.evaluateJavaScript("window.count", in: loaded)) as? Int == 1)
        for _ in 0..<100 where storage.values["count"] == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(storage.values["count"] == "1")
        #expect(WorkshopWebStorage(scope: "first", defaults: defaults).values["count"] == "1")
        #expect(WorkshopWebStorage(scope: "second", defaults: defaults).values.isEmpty)
        let screenFrame = try #require(window.screen?.frame)
        let desktop = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.setInteractionEnabled(true, desktopLevel: desktop)
        window.setInteractionEnabled(false, desktopLevel: desktop)
        #expect(window.frame == screenFrame && player.frame.size == screenFrame.size)
        #expect((try await player.evaluateJavaScript("innerWidth")) as? Double == screenFrame.width)
        #expect((try await player.evaluateJavaScript("innerHeight")) as? Double == screenFrame.height)
        #expect((try await player.evaluateJavaScript("window.count", in: loaded)) as? Int == 1)
        // 换片页会等待静态遮罩的 CSS 动画完成。桌面失焦后，动画不能因 WebKit 的遮挡判断停住。
        _ = try await player.evaluateJavaScript("""
        (() => {
          const cover = document.getElementById('cover');
          getComputedStyle(cover).opacity;
          cover.style.opacity = '0';
          getComputedStyle(cover).opacity;
          window.coverRevealed = false;
          Promise.all(cover.getAnimations().map(animation => animation.finished))
            .then(() => window.coverRevealed = true);
        })()
        """, in: loaded)
        for _ in 0..<100 {
            if (try await player.evaluateJavaScript("window.coverRevealed", in: loaded)) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect((try await player.evaluateJavaScript("window.coverRevealed", in: loaded)) as? Bool == true)
        #expect((try await player.evaluateJavaScript("Number(getComputedStyle(document.getElementById('cover')).opacity)", in: loaded)) as? Double == 0)
        _ = try await player.evaluateJavaScript("""
        window.pendingFade = document.getElementById('cover').animate([{opacity:1}, {opacity:0}], {duration:60000});
        window.wallpaperPropertyListener.setPaused = value => {
          window.pauseNotifications.push(value);
          if (!value) window.pendingFade.cancel();
        };
        void 0;
        """, in: loaded)
        player.pause()
        try await Task.sleep(for: .milliseconds(100))
        #expect((try await player.evaluateJavaScript("document.hidden", in: loaded)) as? Bool == true)
        player.play()
        try await Task.sleep(for: .milliseconds(100))
        #expect((try await player.evaluateJavaScript("document.hidden", in: loaded)) as? Bool == false)
        #expect((try await player.evaluateJavaScript("window.pauseNotifications.includes(true) && window.pauseNotifications.at(-1) === false", in: loaded)) as? Bool == true)
        #expect((try await player.evaluateJavaScript("window.pendingFade.playState", in: loaded)) as? String == "idle")
        #expect(player.runtimeErrors.isEmpty)
    }

    @Test func storageRemovalClearAndQuotaAreIsolated() {
        let defaults = testDefaults.make()
        let store = WorkshopWebStorage(scope: "wallpaper", defaults: defaults)
        store.apply(["operation":"set", "key":"a", "value":"1"])
        store.apply(["operation":"set", "key":"b", "value":"2"])
        store.apply(["operation":"remove", "key":"a"])
        #expect(store.values == ["b":"2"])
        store.apply(["operation":"set", "key":"large", "value":String(repeating:"x", count:WorkshopWebStorage.limit)])
        #expect(store.values == ["b":"2"])
        store.apply(["operation":"clear"])
        #expect(WorkshopWebStorage(scope: "wallpaper", defaults: defaults).values.isEmpty)
    }

    @Test func oldRecordsNeverEnterAutomaticUpdateQueue() {
        let done = WorkshopDownloadJob(id:"123", title:"Old", state:.completed)
        #expect(!WorkshopUpdateStatus.unverified.canEnqueue(job:nil, automatic:true))
        #expect(!WorkshopUpdateStatus.unverified.canEnqueue(job:done, automatic:true))
        #expect(WorkshopUpdateStatus.available.canEnqueue(job:done, automatic:true))
    }

    @Test func desktopOcclusionRequiresRealCoveringWindow() {
        let target = CGRect(x:0,y:30,width:2560,height:1316)
        #expect(!DesktopOcclusionPolicy.isCovered(target, by: []))
        #expect(!DesktopOcclusionPolicy.isCovered(target, by: [CGRect(x:500,y:200,width:1200,height:780)]))
        #expect(DesktopOcclusionPolicy.isCovered(target, by: [CGRect(x:0,y:0,width:2560,height:1440)]))
    }
}
