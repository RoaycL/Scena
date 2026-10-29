import AppKit
import Foundation
import Testing
import WebKit
@testable import wallhaven

@MainActor @Suite(.serialized)
struct WorkshopNavigationTests {
    private let testDefaults = TestDefaults()
    private let site = URL(string: "https://example.com/promo")!

    @Test func policyKeepsTheDesktopOnLocalContent() {
        typealias P = WorkshopNavigationPolicy
        let local = URL(string: "wewall://local/items/1/index.html")!
        #expect(P.decide(url: local, isMainFrame: true, isNewWindow: false, userActivated: false, canOpenExternally: false) == .allow)
        #expect(P.decide(url: URL(string: "blob:wewall://local/abc")!, isMainFrame: false, isNewWindow: false,
                         userActivated: false, canOpenExternally: false) == .allow)
        // 主框架不能离开本地内容
        #expect(P.decide(url: site, isMainFrame: true, isNewWindow: false, userActivated: false, canOpenExternally: true) == .cancel)
        // 壁纸页面不能被脚本换成外部网站，新建的在线 iframe 可以加载
        #expect(P.decide(url: site, isMainFrame: false, isNewWindow: false, userActivated: false,
                         canOpenExternally: false, currentScheme: "blob") == .cancel)
        #expect(P.decide(url: site, isMainFrame: false, isNewWindow: false, userActivated: false,
                         canOpenExternally: false, currentScheme: "about") == .allow)
        // 用户点击外部链接：交互时交给浏览器，非交互时忽略
        #expect(P.decide(url: site, isMainFrame: false, isNewWindow: false, userActivated: true,
                         canOpenExternally: true, currentScheme: "blob") == .openExternally(site))
        #expect(P.decide(url: site, isMainFrame: false, isNewWindow: true, userActivated: false, canOpenExternally: false) == .cancel)
        #expect(P.decide(url: URL(string: "file:///etc/passwd")!, isMainFrame: false, isNewWindow: false,
                         userActivated: false, canOpenExternally: true) == .cancel)
    }

    @Test func scriptedRedirectLeavesTheWallpaperInPlace() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"type":"web","file":"index.html","title":"Navigation"}"#.utf8).write(to: folder.appendingPathComponent("project.json"))
        try """
        <!doctype html><html><body><a id="out" href="https://example.com/promo">out</a>
        <script>window.token = Math.random(); window.ready = true;</script></body></html>
        """.write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let item = try #require(WorkshopItem.load(from: folder, computeSize: false))
        let player = WorkshopPlayerNSView(item: item, storage: WorkshopWebStorage(scope: folder.path,
            defaults: testDefaults.make(), directory: testDefaults.makeDirectory()))
        let window = WallpaperDesktopWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                                            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = player
        window.orderFront(nil)
        defer { player.stop(); window.orderOut(nil); window.contentView = nil; window.close() }
        var loaded: WKFrameInfo?
        for _ in 0..<200 {
            for frame in player.documentFrames where !frame.isMainFrame {
                if (try? await player.evaluateJavaScript("window.ready === true", in: frame)) as? Bool == true { loaded = frame }
            }
            if loaded != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let frame = try #require(loaded)
        let token = try #require(try await player.evaluateJavaScript("window.token", in: frame) as? Double)
        _ = try await player.evaluateJavaScript("document.getElementById('out').click(); location.href = 'https://example.com/redirect'; void 0", in: frame)
        try await Task.sleep(for: .milliseconds(600))
        #expect(try await player.evaluateJavaScript("window.token", in: frame) as? Double == token)
        #expect(try await player.evaluateJavaScript("location.protocol", in: frame) as? String != "https:")
    }

    @Test func webStorageMovesOutOfPreferences() {
        let defaults = testDefaults.make(), directory = testDefaults.makeDirectory()
        let legacy = WorkshopWebStorage(scope: "probe", defaults: defaults, directory: directory)
        legacy.apply(["operation": "set", "key": "mode", "value": "3"])
        // 模拟旧版本：数据在偏好设置里、文件不存在
        let file = try! #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let data = try! Data(contentsOf: file)
        try? FileManager.default.removeItem(at: file)
        let key = "workshop.webStorage.v1." + file.deletingPathExtension().lastPathComponent
        defaults.set(data, forKey: key)

        let migrated = WorkshopWebStorage(scope: "probe", defaults: defaults, directory: directory)
        #expect(migrated.values == ["mode": "3"])
        #expect(defaults.data(forKey: key) == nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
        migrated.apply(["operation": "clear"])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
