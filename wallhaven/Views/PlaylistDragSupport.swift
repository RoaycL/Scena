import AppKit
import Combine
import SwiftUI

/// 高频位置只由浮图观察，不传播到播放列表页面。
final class PlaylistDragPointer: ObservableObject {
    @Published var location = CGPoint.zero
}

/// 拖动期间用窗口鼠标位置驱动边缘滚动；松手或离开页面立即停止。
final class PlaylistDragState: ObservableObject {
    @Published var payload: PlaylistDragPayload?
    @Published var insertionBeforeID: String?
    @Published var insertionPlaylistID: UUID?
    @Published var sidebarTargetID: UUID?
    private weak var scrollView: NSScrollView?
    private var timer: Timer?
    private(set) var isCancelled = false
    var frames: [String: CGRect] = [:]
    let pointer = PlaylistDragPointer()

    func attach(_ scrollView: NSScrollView) { self.scrollView = scrollView }
    func begin(_ payload: PlaylistDragPayload) {
        end()
        self.payload = payload
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    func update(point: CGPoint, playlistID: UUID, ids: [String]) {
        if pointer.location != point { pointer.location = point }
        guard let payload else { return }
        var target = frames.first(where: { $0.key.hasPrefix("list-") && $0.value.contains(point) })
            .flatMap { UUID(uuidString: String($0.key.dropFirst(5))) }
        if target == payload.playlistID { target = nil }
        let insertion = target == nil && frames["viewport"]?.contains(point) == true ? playlistID : nil
        var before: String?
        if insertion != nil {
            let visible = ids.filter { frames[$0] != nil }
            if let next = visible.first(where: { frames[$0]!.midX > point.x }) {
                before = PlaylistEditing.insertionAnchor(ids: ids, hovered: next, after: false, selected: Set(payload.ids))
            } else if let last = visible.last {
                before = PlaylistEditing.insertionAnchor(ids: ids, hovered: last, after: true, selected: Set(payload.ids))
            }
        }
        if sidebarTargetID != target { sidebarTargetID = target }
        if insertionPlaylistID != insertion { insertionPlaylistID = insertion }
        if insertionBeforeID != before { insertionBeforeID = before }
    }

    func cancel() { end(); isCancelled = true }
    func end() {
        isCancelled = false
        timer?.invalidate(); timer = nil
        if payload != nil { payload = nil }
        if insertionBeforeID != nil { insertionBeforeID = nil }
        if insertionPlaylistID != nil { insertionPlaylistID = nil }
        if sidebarTargetID != nil { sidebarTargetID = nil }
    }
    private func tick() {
        guard insertionPlaylistID != nil, sidebarTargetID == nil, let scrollView, let window = scrollView.window,
              let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let point = clip.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let bounds = clip.bounds
        guard point.y >= bounds.minY, point.y <= bounds.maxY,
              point.x >= bounds.minX, point.x <= bounds.maxX else { return }
        let edge: CGFloat = 44
        let distance: CGFloat
        if point.x < bounds.minX + edge { distance = -14 * (1 - (point.x - bounds.minX) / edge) }
        else if point.x > bounds.maxX - edge { distance = 14 * (1 - (bounds.maxX - point.x) / edge) }
        else { return }
        let maximum = max(0, document.frame.width - bounds.width)
        let x = min(max(0, bounds.minX + distance), maximum)
        clip.scroll(to: NSPoint(x: x, y: bounds.minY))
        scrollView.reflectScrolledClipView(clip)
    }
}

struct PlaylistScrollAccessor: NSViewRepresentable {
    let onResolve: (NSScrollView) -> Void
    func makeNSView(context: Context) -> Probe { Probe(onResolve: onResolve) }
    func updateNSView(_ view: Probe, context: Context) { view.resolve() }
    final class Probe: NSView {
        let onResolve: (NSScrollView) -> Void
        init(onResolve: @escaping (NSScrollView) -> Void) { self.onResolve = onResolve; super.init(frame: .zero) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); resolve() }
        func resolve() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let scrollView = self.enclosingScrollView { self.onResolve(scrollView) }
            }
        }
    }
}

/// Tap 回调可能晚于修饰键松开，选择操作使用鼠标按下瞬间的按键状态。
final class PlaylistInteractionInput: ObservableObject {
    private var monitor: Any?
    private(set) var clickModifiers: NSEvent.ModifierFlags = []
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.clickModifiers = event.modifierFlags
            return event
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}


struct PlaylistDragFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func playlistDragFrame(_ key: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: PlaylistDragFramesKey.self,
                value: [key: geometry.frame(in: .named("playlistBoard"))])
        })
    }
}
