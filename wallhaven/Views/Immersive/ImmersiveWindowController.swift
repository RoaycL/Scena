//
//  ImmersiveWindowController.swift
//  wallhaven
//

import AppKit
import Combine
import SwiftUI

/// 主窗口的沉浸式行为：
///  - 鼠标静止一段时间后自动隐藏界面、红绿灯和光标，鼠标一动立即恢复
///  - 键盘快捷键
///  - 在横向缩略图条上，把垂直滚轮转换为水平滚动，并支持拖动滚动
final class ImmersiveWindowController: ObservableObject {
    enum Key {
        case left, right, up, down, space, enter, escape, character(Character)
    }

    @Published private(set) var isChromeHidden = false

    /// 返回 true 表示已处理该按键
    var keyHandler: ((Key) -> Bool)?

    private weak var window: NSWindow?
    private var monitor: Any?
    private var hideTimer: Timer?
    private var menuObservers: [NSObjectProtocol] = []
    /// 子菜单有各自的跟踪周期；只有最后一个菜单关闭后才恢复自动隐藏。
    private var trackingMenus: Set<ObjectIdentifier> = []
    private let idleDelay: TimeInterval = 2.5
    /// 鼠标悬停在界面元素上、搜索框聚焦、弹出面板打开时不自动隐藏
    private var holdReasons: Set<String> = []
    /// 用户按空格手动隐藏后，只有再按空格（或 Esc）才恢复，移动鼠标不恢复
    private var isManuallyHidden = false

    // 拖动滚动状态
    private weak var dragScrollView: NSScrollView?
    private var isDragScrolling = false
    private var dragStartX: CGFloat = 0
    private var dragOriginX: CGFloat = 0

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        menuObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.acceptsMouseMovedEvents = true
        // 启动时不要让搜索框抢走焦点，否则快捷键和自动隐藏都会失效
        DispatchQueue.main.async { window.makeFirstResponder(nil) }
        installMonitor()
        installMenuTracking()
        scheduleHide()
    }

    func setHold(_ reason: String, active: Bool) {
        if active {
            holdReasons.insert(reason)
            hideTimer?.invalidate()
            if !isManuallyHidden { setChromeHidden(false) }
        } else {
            holdReasons.remove(reason)
            scheduleHide()
        }
    }

    func toggleChrome() {
        if isChromeHidden {
            isManuallyHidden = false
            setChromeHidden(false)
            scheduleHide()
        } else {
            isManuallyHidden = true
            hideTimer?.invalidate()
            setChromeHidden(true)
        }
    }

    func showChrome() {
        isManuallyHidden = false
        setChromeHidden(false)
        scheduleHide()
    }

    // MARK: - Auto hide

    private func userDidInteract() {
        guard !isManuallyHidden else { return }
        if isChromeHidden { setChromeHidden(false) }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        guard holdReasons.isEmpty, !isManuallyHidden else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: idleDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.holdReasons.isEmpty, self.window?.isKeyWindow == true else { return }
                self.setChromeHidden(true)
            }
        }
    }

    private func setChromeHidden(_ hidden: Bool) {
        guard hidden != isChromeHidden else { return }
        withAnimation(.easeInOut(duration: hidden ? 0.5 : 0.25)) {
            isChromeHidden = hidden
        }
        // 红绿灯跟随界面一起淡入淡出
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window?.standardWindowButton($0) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = hidden ? 0.5 : 0.25
            buttons.forEach { $0.animator().alphaValue = hidden ? 0 : 1 }
        }
        if hidden {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    // MARK: - Event monitor

    private func installMenuTracking() {
        guard menuObservers.isEmpty else { return }
        menuObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let menu = notification.object as? NSMenu else { return }
                self.trackingMenus.insert(ObjectIdentifier(menu))
                self.setHold("menu", active: true)
            }
        })
        menuObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let menu = notification.object as? NSMenu else { return }
                self.trackingMenus.remove(ObjectIdentifier(menu))
                if self.trackingMenus.isEmpty { self.setHold("menu", active: false) }
            }
        })
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .scrollWheel, .keyDown, .leftMouseDown, .rightMouseDown, .leftMouseDragged, .leftMouseUp]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            return self.handle(event, in: window)
        }
    }

    private func handle(_ event: NSEvent, in window: NSWindow) -> NSEvent? {
        // 菜单使用方向键/滚轮浏览时，不能同时切换图片或移动缩略图条。
        guard trackingMenus.isEmpty else { return event }
        switch event.type {
        case .rightMouseDown:
            userDidInteract()
            return event
        case .mouseMoved:
            userDidInteract()
            return event

        case .keyDown:
            return handleKey(event, in: window)

        case .scrollWheel:
            userDidInteract()
            guard let scrollView = horizontalScrollView(at: event.locationInWindow, in: window) else { return event }
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            // 触控板横向滑动保持原生行为（含惯性）
            if abs(dx) > abs(dy) { return event }
            let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            scroll(scrollView, toX: scrollView.contentView.bounds.origin.x - dy * multiplier)
            return nil

        case .leftMouseDown:
            userDidInteract()
            dragScrollView = horizontalScrollView(at: event.locationInWindow, in: window)
            isDragScrolling = false
            dragStartX = event.locationInWindow.x
            dragOriginX = dragScrollView?.contentView.bounds.origin.x ?? 0
            return event

        case .leftMouseDragged:
            guard let scrollView = dragScrollView else { return event }
            let moved = dragStartX - event.locationInWindow.x
            // 超过阈值才进入拖动模式，避免影响点击
            if !isDragScrolling && abs(moved) < 5 { return event }
            isDragScrolling = true
            scroll(scrollView, toX: dragOriginX + moved)
            return nil

        case .leftMouseUp:
            dragScrollView = nil
            isDragScrolling = false
            return event

        default:
            return event
        }
    }

    private func handleKey(_ event: NSEvent, in window: NSWindow) -> NSEvent? {
        // 输入框聚焦时不拦截；带 ⌘/⌃/⌥ 的组合键交给系统菜单
        if window.firstResponder is NSTextView { return event }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return event }

        let key: Key?
        switch event.keyCode {
        case 123: key = .left
        case 124: key = .right
        case 126: key = .up
        case 125: key = .down
        case 49: key = .space
        case 36, 76: key = .enter
        case 53: key = .escape
        default: key = event.charactersIgnoringModifiers?.lowercased().first.map(Key.character)
        }

        guard let key else { return event }

        switch key {
        case .space:
            toggleChrome()
            return nil
        case .escape:
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            showChrome()
            return nil
        case .character("f"):
            window.toggleFullScreen(nil)
            return nil
        default:
            return keyHandler?(key) == true ? nil : event
        }
    }

    // MARK: - Horizontal scroll helpers

    /// 找出鼠标位置下方、内容比可视区域宽的横向 NSScrollView
    private func horizontalScrollView(at point: NSPoint, in window: NSWindow) -> NSScrollView? {
        guard let contentView = window.contentView else { return nil }
        return Self.findHorizontalScrollView(in: contentView, containing: point)
    }

    private static func findHorizontalScrollView(in view: NSView, containing point: NSPoint) -> NSScrollView? {
        guard !view.isHidden, view.alphaValue > 0 else { return nil }
        if let scrollView = view as? NSScrollView,
           let document = scrollView.documentView,
           document.frame.width > scrollView.frame.width + 1,
           document.frame.height <= scrollView.frame.height + 1,
           scrollView.convert(scrollView.bounds, to: nil).contains(point) {
            return scrollView
        }
        for subview in view.subviews {
            if let found = findHorizontalScrollView(in: subview, containing: point) { return found }
        }
        return nil
    }

    private func scroll(_ scrollView: NSScrollView, toX x: CGFloat) {
        let contentWidth = scrollView.documentView?.frame.width ?? 0
        let maxX = max(0, contentWidth - scrollView.contentView.bounds.width)
        let clampedX = max(0, min(maxX, x))
        scrollView.contentView.scroll(to: NSPoint(x: clampedX, y: scrollView.contentView.bounds.origin.y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// 获取 SwiftUI 视图所在的 NSWindow
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
