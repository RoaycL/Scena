//
//  WorkshopPlayerView.swift
//  wallhaven
//
//  在 WKWebView 中用 webwallgl（MIT，WebGL2）渲染 Wallpaper Engine 壁纸。
//  播放页与壁纸文件都通过自定义协议 wewall://local/ 提供（同源，免 CORS）：
//    wewall://local/player/<file>        → App 内置的播放页与 webwallgl.global.min.js
//    wewall://local/items/<id>/<path>    → 已注册的本地壁纸文件夹
//

import AppKit
import SwiftUI
import WebKit

/// 桌面动态壁纸使用的播放视图（视频与工坊壁纸共用）
protocol LivePlaybackView: NSView {
    func play()
    func pause()
    func stop()
    func setVolume(_ volume: Double)
    /// 第一帧渲染完成（或加载失败）时回调，用于新旧壁纸无缝切换
    func whenReady(_ action: @escaping () -> Void)
    /// 当前显示的画面（退出 App 时定格为静态壁纸）
    func snapshot() async -> CGImage?
}

extension LoopingVideoNSView: LivePlaybackView {}

// MARK: - Scheme handler

final class WorkshopSchemeHandler: NSObject, WKURLSchemeHandler {
    static let shared = WorkshopSchemeHandler()
    static let scheme = "wewall"
    static let playerURL = URL(string: "\(scheme)://local/player/workshop-player.html")!

    private var folders: [String: URL] = [:]
    /// 进行中的请求；WebKit 取消后从这里移除，之后不能再回调
    private var activeTasks: [ObjectIdentifier: WKURLSchemeTask] = [:]

    func register(folder: URL, id: String) {
        folders[id] = folder.standardizedFileURL
    }

    static func baseURL(for id: String) -> String {
        "\(scheme)://local/items/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)"
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        activeTasks[taskID] = urlSchemeTask

        let request = urlSchemeTask.request
        guard let url = request.url, let fileURL = resolve(url) else {
            finish(taskID, url: request.url, result: nil)
            return
        }
        let isHead = request.httpMethod?.uppercased() == "HEAD"
        let range = request.value(forHTTPHeaderField: "Range")

        // 文件读取放到后台，大文件（scene.pkg 可达数百 MB）不阻塞主线程
        Task.detached(priority: .userInitiated) {
            let result = Self.read(fileURL, range: range, headOnly: isHead)
            await self.finish(taskID, url: url, result: result)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        activeTasks[ObjectIdentifier(urlSchemeTask)] = nil
    }

    private func resolve(_ url: URL) -> URL? {
        let parts = url.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard parts.count >= 2 else { return nil }

        switch parts[0] {
        case "player":
            let name = parts[1]
            return Bundle.main.url(forResource: name, withExtension: nil)
                ?? Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "WorkshopPlayer")
        case "items":
            guard let folder = folders[parts[1]] else { return nil }
            let relative = parts.dropFirst(2).joined(separator: "/")
            let fileURL = folder.appendingPathComponent(relative).standardizedFileURL
            // 防止 ../ 越出壁纸目录
            guard fileURL.path.hasPrefix(folder.path + "/") else { return nil }
            return fileURL
        default:
            return nil
        }
    }

    nonisolated private struct ReadResult: Sendable {
        let data: Data
        let totalSize: Int
        let rangeStart: Int?
        let rangeEnd: Int
    }

    nonisolated private static func read(_ url: URL, range: String?, headOnly: Bool) -> ReadResult? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let total = Int((try? handle.seekToEnd()) ?? 0)

        // 支持 Range 请求（<video> 需要）
        if let range, let match = range.firstMatch(of: /bytes=(\d*)-(\d*)/), total > 0 {
            let start = Int(match.1) ?? 0
            let end = min(Int(match.2) ?? (total - 1), total - 1)
            guard start <= end else { return nil }
            if headOnly { return ReadResult(data: Data(), totalSize: total, rangeStart: start, rangeEnd: end) }
            try? handle.seek(toOffset: UInt64(start))
            let data = (try? handle.read(upToCount: end - start + 1)) ?? Data()
            return ReadResult(data: data, totalSize: total, rangeStart: start, rangeEnd: end)
        }

        if headOnly { return ReadResult(data: Data(), totalSize: total, rangeStart: nil, rangeEnd: total - 1) }
        try? handle.seek(toOffset: 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return ReadResult(data: data, totalSize: total, rangeStart: nil, rangeEnd: total - 1)
    }

    private func finish(_ taskID: ObjectIdentifier, url: URL?, result: ReadResult?) {
        // 任务已被 WebKit 取消时不能再回调，否则会崩溃
        guard let task = activeTasks.removeValue(forKey: taskID), let url else { return }

        var headers = [
            "Access-Control-Allow-Origin": "*",
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-cache",
        ]
        guard let result else {
            headers["Content-Length"] = "0"
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: headers)!
            task.didReceive(response)
            task.didFinish()
            return
        }

        headers["Content-Type"] = Self.mimeType(for: url.pathExtension)
        let status: Int
        if let start = result.rangeStart {
            status = 206
            headers["Content-Range"] = "bytes \(start)-\(result.rangeEnd)/\(result.totalSize)"
            headers["Content-Length"] = String(result.rangeEnd - start + 1)
        } else {
            status = 200
            headers["Content-Length"] = String(result.totalSize)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        if !result.data.isEmpty { task.didReceive(result.data) }
        task.didFinish()
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "mp4", "m4v": "video/mp4"
        case "webm": "video/webm"
        case "mov": "video/quicktime"
        case "mp3": "audio/mpeg"
        case "ogg": "audio/ogg"
        case "wav": "audio/wav"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        default: "application/octet-stream"
        }
    }
}

// MARK: - Player view

final class WorkshopPlayerNSView: NSView, LivePlaybackView {
    enum State: Equatable {
        case loading, ready, failed(String)
    }

    var onStateChange: ((State) -> Void)?
    private(set) var state: State = .loading {
        didSet {
            onStateChange?(state)
            if state != .loading {
                let callbacks = readyCallbacks
                readyCallbacks.removeAll()
                callbacks.forEach { $0() }
            }
        }
    }
    private var readyCallbacks: [() -> Void] = []

    func whenReady(_ action: @escaping () -> Void) {
        if state == .loading {
            readyCallbacks.append(action)
        } else {
            action()
        }
    }

    private let item: WorkshopItem
    private let fps: Int
    private let webView: WKWebView
    private var isPageLoaded = false
    private var wantsPlaying = true
    private var volume = 0.0
    private var lastPointerPush = Date.distantPast

    init(item: WorkshopItem, fps: Int = 30, tracksMouse: Bool = false) {
        self.item = item
        self.fps = fps

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(WorkshopSchemeHandler.shared, forURLScheme: WorkshopSchemeHandler.scheme)
        config.mediaTypesRequiringUserActionForPlayback = []
        config.suppressesIncrementalRendering = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        webView.isInspectable = true
        #endif

        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
        config.userContentController.add(WeakScriptMessageHandler(self), name: "host")

        if tracksMouse {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
        }

        if let folder = item.localFolder {
            WorkshopSchemeHandler.shared.register(folder: folder, id: item.id)
            webView.load(URLRequest(url: WorkshopSchemeHandler.playerURL))
        } else {
            state = .failed("壁纸尚未下载")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    /// 不拦截鼠标事件，让上层 SwiftUI 界面正常交互
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }
        pushPointer(u: point.x / bounds.width, v: 1 - point.y / bounds.height)
    }

    func play() {
        wantsPlaying = true
        call("__host.resume()")
    }

    func pause() {
        wantsPlaying = false
        call("__host.pause()")
    }

    func snapshot() async -> CGImage? {
        guard isPageLoaded, let image = try? await webView.takeSnapshot(configuration: nil) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func setVolume(_ volume: Double) {
        self.volume = min(1, max(0, volume))
        call("__host.setVolume(\(self.volume))")
    }

    func stop() {
        call("__host.pause()")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "host")
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    /// 归一化坐标（0..1，y 向下），30Hz 节流
    func pushPointer(u: CGFloat, v: CGFloat) {
        guard isPageLoaded, Date().timeIntervalSince(lastPointerPush) > 1.0 / 30 else { return }
        lastPointerPush = Date()
        call("__host.pointer(\(Double(u)),\(Double(v)))")
    }

    fileprivate func handle(message: [String: Any]) {
        switch message["type"] as? String {
        case "loaded":
            isPageLoaded = true
            let base = WorkshopSchemeHandler.baseURL(for: item.id)
            call("__host.load('\(base)', { fps: \(fps), volume: \(volume) })")
        case "ready":
            state = .ready
            call("__host.setVolume(\(volume))")
            if !wantsPlaying { call("__host.pause()") }
        case "error":
            state = .failed(message["message"] as? String ?? "渲染失败")
        default:
            break
        }
    }

    private func call(_ script: String) {
        guard isPageLoaded else { return }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}

/// WKUserContentController 会强引用 handler，用弱引用代理避免循环引用
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WorkshopPlayerNSView?

    init(_ target: WorkshopPlayerNSView) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        target?.handle(message: body)
    }
}

/// SwiftUI 包装：App 内背景实时预览
struct WorkshopPlayerView: NSViewRepresentable {
    let item: WorkshopItem
    var onStateChange: (WorkshopPlayerNSView.State) -> Void = { _ in }

    func makeNSView(context: Context) -> WorkshopPlayerNSView {
        let view = WorkshopPlayerNSView(item: item, fps: 60, tracksMouse: true)
        view.onStateChange = onStateChange
        return view
    }

    func updateNSView(_ nsView: WorkshopPlayerNSView, context: Context) {}

    static func dismantleNSView(_ nsView: WorkshopPlayerNSView, coordinator: ()) {
        nsView.stop()
    }
}
