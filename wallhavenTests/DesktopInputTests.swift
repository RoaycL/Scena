import AppKit
import Testing
import WebKit
@testable import wallhaven

@MainActor
@Suite(.serialized)
struct DesktopInputTests {
    private let testDefaults = TestDefaults()

    @Test func emptyDesktopIgnoresDesktopLayersOwnWindowsAndOverlays() {
        let point = CGPoint(x: 400, y: 400)
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let cursorLayer = Int(CGWindowLevelForKey(.cursorWindow))
        let desktopIcons = Int(CGWindowLevelForKey(.desktopIconWindow))
        // 桌面本身（负层级）、自己的壁纸窗口、光标覆盖层、透明窗口都不算遮挡
        #expect(DesktopHitTest.isUncovered(point, by: [
            .init(number: 1, layer: desktopIcons, alpha: 1, bounds: screen),
            .init(number: 2, layer: 0, alpha: 1, bounds: screen),
            .init(number: 3, layer: cursorLayer, alpha: 1, bounds: CGRect(x: 390, y: 390, width: 32, height: 32)),
            .init(number: 4, layer: 0, alpha: 0, bounds: screen),
            .init(number: 5, layer: 0, alpha: 1, bounds: CGRect(x: 900, y: 100, width: 600, height: 400)),
        ], ignoring: [2]))
        // 普通窗口、菜单栏、程序坞在上方时不转发
        #expect(!DesktopHitTest.isUncovered(point, by: [.init(number: 6, layer: 0, alpha: 1, bounds: CGRect(x: 200, y: 200, width: 600, height: 400))], ignoring: []))
        #expect(!DesktopHitTest.isUncovered(CGPoint(x: 400, y: 10), by: [.init(number: 7, layer: 24, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 2560, height: 30))], ignoring: []))
        #expect(!DesktopHitTest.isUncovered(CGPoint(x: 1280, y: 1400), by: [.init(number: 8, layer: 20, alpha: 1, bounds: CGRect(x: 600, y: 1360, width: 1360, height: 80))], ignoring: []))
    }

    @Test func finderDesktopBackgroundRolesAreNotIcons() {
        #expect(DesktopHitTest.isDesktopBackgroundRole("AXScrollArea"))
        #expect(DesktopHitTest.isDesktopBackgroundRole("AXGroup"))
        #expect(DesktopHitTest.isDesktopBackgroundRole(nil))
        #expect(!DesktopHitTest.isDesktopBackgroundRole("AXImage"))
        #expect(!DesktopHitTest.isDesktopBackgroundRole("AXTextField"))
    }

    @Test func desktopWindowInputModes() {
        let window = WallpaperDesktopWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                                            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // 直接点壁纸不能把 Scena 切到前台，也不能在 App 失焦时隐藏
        #expect(window.styleMask.contains(.nonactivatingPanel))
        #expect(!window.hidesOnDeactivate)
        let desktop = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.setInputMode(.desktop, desktopLevel: desktop)
        #expect(!window.ignoresMouseEvents && !window.canBecomeKey && window.level == desktop && !window.allowsInteraction)
        window.setInputMode(.interacting, desktopLevel: desktop)
        #expect(!window.ignoresMouseEvents && window.canBecomeKey && window.level == .normal && window.allowsInteraction)
        window.setInputMode(.passive, desktopLevel: desktop)
        #expect(window.ignoresMouseEvents && !window.canBecomeKey && window.level == desktop)
    }

    @Test func forwardedPointerEventsReachSandboxedPage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"type":"web","file":"index.html","title":"Pointer forwarding"}"#.utf8).write(to: folder.appendingPathComponent("project.json"))
        let html = """
        <!doctype html><html><head><style>
        html,body {margin:0;width:100%;height:100%;overflow:hidden}
        #button {position:absolute;left:0;top:0;width:200px;height:200px}
        #list {position:absolute;left:300px;top:0;width:200px;height:100px;overflow:auto}
        #list div {height:1000px}
        </style></head><body><button id="button">Tap</button><div id="list"><div></div></div><script>
        window.log = [];
        window.clicks = 0;
        const button = document.getElementById('button');
        for (const type of ['pointerdown','mousedown','pointerup','mouseup','mousemove','mouseenter','mouseleave'])
          button.addEventListener(type, event => log.push(type + ':' + event.buttons));
        button.addEventListener('click', () => clicks++);
        window.addEventListener('wheel', event => log.push('wheel:' + event.deltaY));
        window.started = true;
        </script></body></html>
        """
        try html.write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let item = try #require(WorkshopItem.load(from: folder, computeSize: false))
        let player = WorkshopPlayerNSView(item: item,
            storage: WorkshopWebStorage(scope: folder.path, defaults: testDefaults.make(), directory: testDefaults.makeDirectory()))
        let window = WallpaperDesktopWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                                            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = player
        window.orderFront(nil)
        defer { player.stop(); window.orderOut(nil); window.contentView = nil; window.close() }
        var loaded: WKFrameInfo?
        for _ in 0..<200 {
            for frame in player.documentFrames where !frame.isMainFrame {
                if (try? await player.evaluateJavaScript("window.started === true", in: frame)) as? Bool == true { loaded = frame; break }
            }
            if loaded != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let frame = try #require(loaded, "Page failed to initialize: \(player.runtimeErrors)")

        // 窗口穿透时视图不拦截鼠标；直接接收鼠标时交给网页
        #expect(player.hitTest(NSPoint(x: 10, y: 10)) == nil)
        player.setInputMode(.desktop)
        #expect(player.hitTest(NSPoint(x: 10, y: 10)) != nil)
        player.setInputMode(.passive)

        player.forwardPointer(.move, x: 50, y: 50)
        player.forwardPointer(.down, x: 50, y: 50)
        player.forwardPointer(.move, x: 60, y: 60)
        player.forwardPointer(.up, x: 60, y: 60)
        // 在一处按下、拖到别处松开不是点击
        player.forwardPointer(.down, x: 50, y: 50)
        player.forwardPointer(.up, x: 600, y: 300)
        player.forwardPointer(.wheel, x: 400, y: 50, deltaY: 120)
        player.forwardPointer(.leave, x: 0, y: 0)
        var log: [String] = []
        for _ in 0..<100 {
            log = (try await player.evaluateJavaScript("window.log", in: frame)) as? [String] ?? []
            if log.contains("mouseleave:0") && log.contains(where: { $0.hasPrefix("wheel") }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Array(log.prefix(7)) == ["mouseenter:0", "mousemove:0", "pointerdown:1", "mousedown:1", "mousemove:1", "pointerup:0", "mouseup:0"])
        #expect(log.contains("wheel:120"))
        #expect((try await player.evaluateJavaScript("window.clicks", in: frame)) as? Int == 1)
        // 滚轮没有被页面取消时滚动鼠标下方的可滚动区域
        #expect((try await player.evaluateJavaScript("document.getElementById('list').scrollTop", in: frame)) as? Double == 120)
        #expect(player.runtimeErrors.isEmpty)
    }
}
