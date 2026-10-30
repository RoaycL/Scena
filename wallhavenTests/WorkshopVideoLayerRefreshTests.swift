import AppKit
import AVFoundation
import CoreVideo
import Testing
import WebKit
@testable import wallhaven

/// 视频画面层重建：可见的视频显示状态变化后原地重新插入（WebKit 按真实尺寸重建画面层），隐藏的视频不动
@MainActor @Suite(.serialized)
struct WorkshopVideoLayerRefreshTests {
    private let testDefaults = TestDefaults()

    @Test func visibleVideosAreReattachedWithoutInterruptingPlayback() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await makeMovie(at: folder.appendingPathComponent("clip.mov"))
        try Data(#"{"type":"web","file":"index.html","title":"Layer rebuild"}"#.utf8).write(to: folder.appendingPathComponent("project.json"))
        // 和换片页面一样：两个视频叠放，下一段在透明度为 0 的元素里加载，显示时切换 class
        let html = """
        <!doctype html><html><head><style>
        html,body {margin:0;width:100%;height:100%;overflow:hidden}
        video {position:absolute;inset:0;width:100%;height:100%;object-fit:contain;opacity:0}
        video.visible {opacity:1}
        </style></head><body>
        <video id="current" class="visible" src="clip.mov" muted autoplay loop playsinline style="object-position: left top"></video>
        <video id="next" src="clip.mov" muted loop playsinline preload="auto"></video>
        <script>
        window.removed = {current: 0, next: 0};
        new MutationObserver(records => records.forEach(r => r.removedNodes.forEach(n => n.id in removed && removed[n.id]++)))
          .observe(document.body, {childList: true});
        window.ready = true;
        </script></body></html>
        """
        try html.write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let item = try #require(WorkshopItem.load(from: folder, computeSize: false))
        let player = WorkshopPlayerNSView(item: item, storage: WorkshopWebStorage(scope: folder.path, defaults: testDefaults.make(), directory: testDefaults.makeDirectory()))
        let window = WallpaperDesktopWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                                            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = player
        window.orderFront(nil)
        defer { player.stop(); window.orderOut(nil); window.contentView = nil; window.close() }

        var loaded: WKFrameInfo?
        for _ in 0..<240 {
            for frame in player.documentFrames where !frame.isMainFrame {
                let ready = try? await player.evaluateJavaScript(
                    "window.ready && [...document.querySelectorAll('video')].every(v => v.videoWidth > 0) && !current.paused", in: frame)
                if ready as? Bool == true { loaded = frame }
            }
            if loaded != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let frame = try #require(loaded, "Video failed to load: \(player.runtimeErrors)")
        // 读到尺寸、开始播放后重建过可见的视频；隐藏的视频不动
        try await Task.sleep(for: .milliseconds(500))
        let removed = "JSON.stringify(window.removed)"
        #expect(try await player.evaluateJavaScript(removed, in: frame) as? String == #"{"current":1,"next":0}"#)

        // 切换：下一段显示出来、当前段隐藏后，只重建新显示的那个
        _ = try await player.evaluateJavaScript("next.play(); next.classList.add('visible'); current.classList.remove('visible'); void 0", in: frame)
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await player.evaluateJavaScript(removed, in: frame) as? String == #"{"current":1,"next":1}"#)
        // 元素还在原位，继续播放，作者样式不变
        #expect(try await player.evaluateJavaScript("[...document.body.children].map(e => e.id).slice(0, 2).join()", in: frame) as? String == "current,next")
        let before = try #require(try await player.evaluateJavaScript("next.currentTime", in: frame) as? Double)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await player.evaluateJavaScript("!next.paused && next.currentTime", in: frame) as? Double ?? 0 > before)
        #expect(try await player.evaluateJavaScript("current.style.getPropertyValue('object-position')", in: frame) as? String == "left top")
        #expect(player.runtimeErrors.isEmpty)
    }

    private func makeMovie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 160, 90, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 128, CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<60 {
            for _ in 0..<200 {
                if input.isReadyForMoreMediaData { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(input.isReadyForMoreMediaData)
            try #require(adapter.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 6, preferredTimescale: 600))
        await writer.finishWriting()
        try #require(writer.status == .completed)
    }
}
