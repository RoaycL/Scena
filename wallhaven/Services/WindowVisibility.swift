import AppKit
import SwiftUI

/// 只观察所属窗口，不使用前台应用状态代替可见性：失焦的窗口仍可能看得见。
final class WindowVisibilityObserver {
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }

    func attach(to window: NSWindow?) {
        stop()
        self.window = window
        guard let window else { onChange(false); return }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    if notification.name == NSWindow.willCloseNotification { self?.onChange(false) }
                    else { self?.evaluate() }
                }
            })
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            })
        }
        evaluate()
    }

    private func evaluate() {
        onChange(window?.isVisible == true && window?.isMiniaturized == false
            && window?.occlusionState.contains(.visible) == true && !NSApp.isHidden)
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        window = nil
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

/// 保留首帧准备；隐藏只阻止持续播放，避免透明等待中的新视图永远拿不到首帧。
nonisolated enum PreviewPlaybackPolicy {
    static func shouldPlay(wantsPlaying: Bool, isReady: Bool, isVisible: Bool) -> Bool {
        wantsPlaying && (!isReady || isVisible)
    }
}

private struct WindowVisibilityProbe: NSViewRepresentable {
    var onChange: (Bool) -> Void

    final class ProbeView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var generation = 0
        private lazy var observer = WindowVisibilityObserver { [weak self] visible in
            guard let self else { return }
            let token = self.generation
            // 避免在 SwiftUI 的 AppKit 更新事务内部修改 @State。
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.onChange(visible)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            generation += 1
            observer.attach(to: window)
        }
        func detach() { generation += 1; observer.stop() }
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }
    func updateNSView(_ nsView: ProbeView, context: Context) { nsView.onChange = onChange }
    static func dismantleNSView(_ nsView: ProbeView, coordinator: ()) { nsView.detach() }
}

private struct ActiveRotation: ViewModifier {
    @State private var spinning = false
    let duration: Double

    func body(content: Content) -> some View {
        content.rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) { spinning = true }
            }
    }
}

private struct VisibleRotation: ViewModifier {
    let enabled: Bool
    let duration: Double
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @State private var visible = false
    @State private var appeared = false

    func body(content: Content) -> some View {
        ZStack {
            if enabled && visible && appeared && !reducesMotion {
                content.modifier(ActiveRotation(duration: duration))
            } else {
                content
            }
        }
        .background(WindowVisibilityProbe { visible = $0 }.frame(width: 0, height: 0))
        .onAppear { appeared = true }
        .onDisappear { appeared = false }
    }
}

extension View {
    func rotatingWhileVisible(_ enabled: Bool = true, duration: Double = 1) -> some View {
        modifier(VisibleRotation(enabled: enabled, duration: duration))
    }
}
