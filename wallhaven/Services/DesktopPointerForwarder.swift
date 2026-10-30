//
//  DesktopPointerForwarder.swift
//  wallhaven
//
//  「点击桌面空白处」交互：壁纸窗口留在桌面图标下面、鼠标照常交给 Finder，
//  同时监听桌面上的点按、拖拽、滚轮和移动，落在空白处时转成网页壁纸里的指针事件。
//

import AppKit
import ApplicationServices

nonisolated enum DesktopPointerEvent {
    enum Kind: String { case move, down, up, wheel, leave }
}

/// 判断鼠标是否落在桌面空白处：上方没有其他窗口、菜单栏、程序坞，也不在桌面图标上
nonisolated enum DesktopHitTest {
    struct WindowEntry: Equatable {
        let number: Int
        let layer: Int
        let alpha: Double
        let bounds: CGRect
    }

    /// point 为 Quartz 坐标（主屏左上角为原点）。负层级是桌面本身；屏保及以上层级是光标、截屏等系统覆盖层
    static func isUncovered(_ point: CGPoint, by windows: [WindowEntry], ignoring own: Set<Int>) -> Bool {
        let maxLayer = Int(CGWindowLevelForKey(.screenSaverWindow))
        return !windows.contains { window in
            window.layer >= 0 && window.layer < maxLayer && window.alpha > 0.01
                && !own.contains(window.number) && window.bounds.contains(point)
        }
    }

    static func onScreenWindows() -> [WindowEntry] {
        let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let bounds = (entry[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) })
            else { return nil }
            return WindowEntry(number: number, layer: layer, alpha: entry[kCGWindowAlpha as String] as? Double ?? 1, bounds: bounds)
        }
    }

    /// 需要辅助功能权限才能区分桌面图标和空白处；没有权限时按空白处处理
    static func isOnDesktopIcon(_ point: CGPoint) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let system = AXUIElementCreateSystemWide()
        // Finder 忙时不能卡住主线程
        AXUIElementSetMessagingTimeout(system, 0.05)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return false }
        var pid: pid_t = 0
        AXUIElementGetPid(hit, &pid)
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.finder" else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &role)
        // 桌面本身是滚动区域里的分组；图标和文件名是其中的图片、文本
        return !isDesktopBackgroundRole(role as? String)
    }

    static func isDesktopBackgroundRole(_ role: String?) -> Bool {
        [kAXScrollAreaRole, kAXGroupRole, kAXApplicationRole, kAXWindowRole].contains(role ?? kAXGroupRole)
    }
}

@MainActor
final class DesktopPointerForwarder {
    struct Target {
        let frame: CGRect
        let player: WorkshopPlayerNSView
    }

    /// 当前可交互的网页壁纸（每块屏幕一个）
    var targets: () -> [Target] = { [] }
    /// 自己的桌面窗口（盖住图标时它们在图标层之上，不能算作遮挡）
    var ownWindowNumbers: () -> Set<Int> = { [] }
    /// 桌面图标被壁纸盖住时不需要区分图标
    var iconsHidden: () -> Bool = { false }

    private var monitors: [Any] = []
    private weak var pressed: WorkshopPlayerNSView?
    private weak var hovered: WorkshopPlayerNSView?
    private var lastMove = Date.distantPast
    private var cachedHit: (time: Date, point: CGPoint, empty: Bool)?

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        // 点按落在桌面上时事件属于 Finder，只有全局监听能收到；鼠标移动在 Scena 处于前台时只发给本 App
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .mouseMoved, .scrollWheel], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let hovered { hovered.forwardPointer(.leave, x: 0, y: 0) }
        hovered = nil
        pressed = nil
        cachedHit = nil
    }

    private func handle(_ event: NSEvent) {
        let location = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            guard let target = target(at: location), isEmptyDesktop(location, maxAge: 0) else {
                pressed = nil
                return
            }
            pressed = target.player
            send(.down, to: target, at: location)
        case .leftMouseDragged:
            // 按下时在空白处才算拖拽壁纸；拖到窗口上方也继续交给同一个壁纸
            guard let player = pressed, let target = targets().first(where: { $0.player === player }), throttle() else { return }
            send(.move, to: target, at: location)
        case .leftMouseUp:
            guard let player = pressed, let target = targets().first(where: { $0.player === player }) else { return }
            pressed = nil
            send(.up, to: target, at: location)
        case .mouseMoved:
            guard pressed == nil, throttle() else { return }
            if let target = target(at: location), isEmptyDesktop(location, maxAge: 0.2) {
                send(.move, to: target, at: location)
            } else {
                leaveHovered()
            }
        case .scrollWheel:
            guard let target = target(at: location), isEmptyDesktop(location, maxAge: 0.2) else { return }
            // 网页里 deltaY 为正表示向下滚动，和 AppKit 的方向相反；滚轮按行计数，换算成像素
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 16
            send(.wheel, to: target, at: location, deltaX: -event.scrollingDeltaX * scale, deltaY: -event.scrollingDeltaY * scale)
        default:
            break
        }
    }

    private func throttle() -> Bool {
        guard Date().timeIntervalSince(lastMove) >= 1.0 / 30 else { return false }
        lastMove = Date()
        return true
    }

    private func target(at location: CGPoint) -> Target? {
        targets().first { $0.frame.contains(location) }
    }

    private func send(_ kind: DesktopPointerEvent.Kind, to target: Target, at location: CGPoint, deltaX: CGFloat = 0, deltaY: CGFloat = 0) {
        if hovered !== target.player { leaveHovered() }
        hovered = target.player
        target.player.forwardPointer(kind, x: location.x - target.frame.minX, y: target.frame.maxY - location.y,
                                     deltaX: deltaX, deltaY: deltaY)
    }

    private func leaveHovered() {
        hovered?.forwardPointer(.leave, x: 0, y: 0)
        hovered = nil
    }

    /// 窗口列表和辅助功能查询都要跨进程，移动和滚轮复用很短时间内的结果
    private func isEmptyDesktop(_ location: CGPoint, maxAge: TimeInterval) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        let point = CGPoint(x: location.x, y: primary.frame.height - location.y)
        if let cachedHit, Date().timeIntervalSince(cachedHit.time) < maxAge, hypot(cachedHit.point.x - point.x, cachedHit.point.y - point.y) < 24 {
            return cachedHit.empty
        }
        let empty = DesktopHitTest.isUncovered(point, by: DesktopHitTest.onScreenWindows(), ignoring: ownWindowNumbers())
            && (iconsHidden() || !DesktopHitTest.isOnDesktopIcon(point))
        cachedHit = (Date(), point, empty)
        return empty
    }
}
