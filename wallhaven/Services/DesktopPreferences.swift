//
//  DesktopPreferences.swift
//  wallhaven
//
//  桌面相关偏好：开机启动、Dock 图标、自动暂停、全局快捷键、动态壁纸的显示方式。
//

import AppKit
import Carbon.HIToolbox
import Combine
import IOKit.ps
import ServiceManagement

enum DesktopSettings {
    static let syncStaticWallpaper = "desktop.syncStaticWallpaper"
    static let keepAspectRatio = "desktop.keepAspectRatio"
    static let backgroundColor = "desktop.backgroundColor"
    static let coverDesktopIcons = "desktop.coverDesktopIcons"
    static let disabledDisplays = "desktop.disabledDisplays"
    static let showDockIcon = "app.showDockIcon"

    static let pauseWhenOtherAppActive = "autoPause.otherAppActive"
    static let pauseWhenFullScreen = "autoPause.fullScreen"
    static let pauseOnBattery = "autoPause.battery"
    static let pauseWhenIdle = "autoPause.idle"
    static let idleMinutes = "autoPause.idleMinutes"

    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    static var backgroundNSColor: NSColor {
        UserDefaults.standard.string(forKey: backgroundColor).flatMap(NSColor.init(hex:)) ?? .black
    }

    static var disabledDisplayIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: disabledDisplays) ?? [])
    }
}

extension NSScreen {
    /// 稳定的显示器标识：重新插拔、重启后不变
    var displayUUID: String {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return localizedName }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

extension NSColor {
    nonisolated convenience init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }

    nonisolated var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X",
                      Int(round(color.redComponent * 255)),
                      Int(round(color.greenComponent * 255)),
                      Int(round(color.blueComponent * 255)))
    }
}

// MARK: - 开机启动 / Dock 图标

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

enum DockIcon {
    static func apply() {
        let show = DesktopSettings.bool(DesktopSettings.showDockIcon, default: true)
        let policy: NSApplication.ActivationPolicy = show ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // 切换后窗口可能失去焦点，重新激活
        if !show { DispatchQueue.main.async { NSApp.activate() } }
    }
}

// MARK: - 自动暂停

/// 根据设置判断动态壁纸是否应该自动暂停。用户手动暂停的优先级更高（由 LiveWallpaperController 处理）
final class AutoPauseMonitor {
    enum Reason: Hashable {
        case otherAppActive, fullScreen, battery, idle

        var label: String {
            switch self {
            case .otherAppActive: "其他 App 正在使用"
            case .fullScreen: "有 App 全屏"
            case .battery: "使用电池供电"
            case .idle: "电脑处于不活跃状态"
            }
        }
    }

    var onChange: (() -> Void)?
    private(set) var reasons: Set<Reason> = []
    /// 被全屏窗口盖住的显示器（只暂停这些屏幕上的动态壁纸）
    private(set) var fullScreenDisplays: Set<String> = []

    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // 切换全屏有动画，稍后再检查一次
                MainActor.assumeIsolated { self?.evaluate() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.evaluate() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        })
        // 电源、不活跃时间没有方便的通知，定时检查（开销很小）
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        evaluate()
    }

    func evaluate() {
        var next = Set<Reason>()
        let front = NSWorkspace.shared.frontmostApplication
        if DesktopSettings.bool(DesktopSettings.pauseWhenOtherAppActive, default: false),
           let front, front.bundleIdentifier != "com.apple.finder", front.processIdentifier != getpid() {
            next.insert(.otherAppActive)
        }
        var covered = Set<String>()
        if DesktopSettings.bool(DesktopSettings.pauseWhenFullScreen, default: true),
           let front, front.processIdentifier != getpid() {
            covered = Self.fullScreenDisplays(pid: front.processIdentifier)
            if !covered.isEmpty { next.insert(.fullScreen) }
        }
        if DesktopSettings.bool(DesktopSettings.pauseOnBattery, default: false), Self.isOnBattery {
            next.insert(.battery)
        }
        if DesktopSettings.bool(DesktopSettings.pauseWhenIdle, default: false) {
            let minutes = max(1, UserDefaults.standard.object(forKey: DesktopSettings.idleMinutes) as? Int ?? 10)
            if Self.idleSeconds >= Double(minutes * 60) { next.insert(.idle) }
        }
        guard next != reasons || covered != fullScreenDisplays else { return }
        reasons = next
        fullScreenDisplays = covered
        onChange?()
    }

    /// 前台 App 铺满整块屏幕的窗口（全屏视频、游戏、全屏模式）所在的显示器
    private static func fullScreenDisplays(pid: pid_t) -> Set<String> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        // CGWindow 坐标原点在主屏左上角，NSScreen 在左下角
        let screens = NSScreen.screens.map { screen -> (String, CGRect) in
            let frame = screen.frame
            return (screen.displayUUID, CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height))
        }
        var result = Set<String>()
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { continue }
            for (id, frame) in screens where abs(frame.minX - bounds.minX) < 1 && abs(frame.minY - bounds.minY) < 1
                && abs(frame.width - bounds.width) < 1 && abs(frame.height - bounds.height) < 1 {
                result.insert(id)
            }
        }
        return result
    }

    private static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    private static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}

// MARK: - 全局快捷键

struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon 修饰键（cmdKey / optionKey / controlKey / shiftKey）
    var modifiers: UInt32
    var display: String
}

/// 系统范围的快捷键（App 在后台时也有效），用 Carbon RegisterEventHotKey 实现，不需要辅助功能权限
final class GlobalHotKeys: ObservableObject {
    enum Action: String, CaseIterable, Identifiable {
        case togglePause, nextWallpaper, showMainWindow

        var id: String { rawValue }

        var title: String {
            switch self {
            case .togglePause: "暂停 / 继续动态壁纸"
            case .nextWallpaper: "下一张壁纸（播放列表）"
            case .showMainWindow: "显示 Scena"
            }
        }

        fileprivate var hotKeyID: UInt32 {
            switch self {
            case .togglePause: 1
            case .nextWallpaper: 2
            case .showMainWindow: 3
            }
        }

        fileprivate var defaultsKey: String { "hotKey.\(rawValue)" }
    }

    static let shared = GlobalHotKeys()

    @Published private(set) var combos: [Action: HotKeyCombo] = [:]
    private var refs: [Action: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private let defaults: UserDefaults
    private let registration: ((HotKeyCombo, Action) -> EventHotKeyRef?)?
    private let unregister: (EventHotKeyRef) -> Void
    private let installsNativeHandler: Bool

    init(defaults: UserDefaults = .standard,
         registration: ((HotKeyCombo, Action) -> EventHotKeyRef?)? = nil,
         unregister: @escaping (EventHotKeyRef) -> Void = { UnregisterEventHotKey($0) },
         installsNativeHandler: Bool = true) {
        self.defaults = defaults
        self.registration = registration
        self.unregister = unregister
        self.installsNativeHandler = installsNativeHandler
        for action in Action.allCases {
            if let data = defaults.data(forKey: action.defaultsKey),
               let combo = try? JSONDecoder().decode(HotKeyCombo.self, from: data) {
                combos[action] = combo
            }
        }
    }

    /// App 启动时注册已保存的快捷键
    func registerAll() {
        installHandler()
        for action in Action.allCases { register(action) }
    }

    func set(_ combo: HotKeyCombo?, for action: Action) {
        installHandler()
        if let combo {
            if let old = combos[action], old.keyCode == combo.keyCode, old.modifiers == combo.modifiers,
               refs[action] != nil { return }
            guard !combos.contains(where: { $0.key != action && $0.value.keyCode == combo.keyCode && $0.value.modifiers == combo.modifiers }) else {
                ToastCenter.shared.show("该快捷键已用于另一个 Scena 操作，原快捷键已保留", style: .error)
                return
            }
            // 先申请新快捷键；失败时不触碰原注册和已保存设置。
            guard let replacement = makeReference(combo, for: action) else { return }
            if let old = refs[action] { unregister(old) }
            refs[action] = replacement
        } else {
            if let old = refs.removeValue(forKey: action) { unregister(old) }
        }
        combos[action] = combo
        if let combo, let data = try? JSONEncoder().encode(combo) {
            defaults.set(data, forKey: action.defaultsKey)
        } else {
            defaults.removeObject(forKey: action.defaultsKey)
        }
    }

    private func register(_ action: Action) {
        guard refs[action] == nil, let combo = combos[action],
              let ref = makeReference(combo, for: action) else { return }
        refs[action] = ref
    }

    private func makeReference(_ combo: HotKeyCombo, for action: Action) -> EventHotKeyRef? {
        if let registration { return registration(combo, action) }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x53434E41), id: action.hotKeyID)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            ToastCenter.shared.show("无法注册快捷键 \(combo.display)，原快捷键已保留", style: .error)
            return nil
        }
        return ref
    }

    private func installHandler() {
        guard installsNativeHandler, handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalHotKeys.shared.fire(id) }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private func fire(_ id: UInt32) {
        guard let action = Action.allCases.first(where: { $0.hotKeyID == id }) else { return }
        switch action {
        case .togglePause:
            let live = LiveWallpaperController.shared
            if live.isActive {
                live.togglePause()
                ToastCenter.shared.show(live.isPaused ? "动态壁纸已暂停" : "动态壁纸继续播放", style: .info)
            }
        case .nextWallpaper:
            PlaylistManager.shared.next()
        case .showMainWindow:
            MainWindow.show()
        }
    }

    /// 把按键事件转换成快捷键（必须包含 ⌘ / ⌃ / ⌥ 之一）
    static func combo(from event: NSEvent) -> HotKeyCombo? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
        return HotKeyCombo(keyCode: UInt32(event.keyCode), modifiers: carbon, display: symbols + keyName(event))
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_Tab: return "⇥"
        default:
            return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}
