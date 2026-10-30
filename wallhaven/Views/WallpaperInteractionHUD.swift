import AppKit
import SwiftUI

/// 桌面壁纸窗口。用不激活 App 的面板：直接在桌面上点壁纸时不会把 Scena 切到前台、改变菜单栏。
/// 只有显式进入网页交互时才允许成为键盘窗口。
final class WallpaperDesktopWindow: NSPanel {
    enum InputMode: Equatable {
        /// 鼠标穿透到桌面图标
        case passive
        /// 留在桌面层级，直接接收鼠标但不抢键盘焦点（「壁纸直接接收鼠标」）
        case desktop
        /// 进入交互：普通窗口层级，接收鼠标和键盘
        case interacting
    }

    private(set) var inputMode: InputMode = .passive
    var allowsInteraction: Bool { inputMode == .interacting }
    /// Finder 的桌面图标窗口可令底层壁纸被系统标为遮挡。保留真实值供宿主决定是否暂停。
    var systemOcclusionState: NSWindow.OcclusionState { super.occlusionState }
    /// WKWebView 除了定时器，还会因窗口遮挡停止 CSS / 视频合成。播放暂停由宿主统一管理。
    override var occlusionState: NSWindow.OcclusionState {
        isVisible ? super.occlusionState.union(.visible) : super.occlusionState
    }
    override var canBecomeKey: Bool { inputMode == .interacting }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style.union(.nonactivatingPanel), backing: backing, defer: flag)
        // 面板默认在 App 失焦时隐藏，壁纸必须一直显示
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
    }

    func setInteractionEnabled(_ enabled: Bool, desktopLevel: NSWindow.Level) {
        setInputMode(enabled ? .interacting : .passive, desktopLevel: desktopLevel)
    }

    func setInputMode(_ mode: InputMode, desktopLevel: NSWindow.Level) {
        let targetFrame = screen?.frame ?? frame
        inputMode = mode
        ignoresMouseEvents = mode == .passive
        acceptsMouseMovedEvents = mode != .passive
        level = mode == .interacting ? .normal : desktopLevel
        (contentView as? WorkshopPlayerNSView)?.setInputMode(mode)
        setFrame(targetFrame, display: true)
        contentView?.frame = NSRect(origin: .zero, size: targetFrame.size)
        contentView?.needsLayout = true
        contentView?.layoutSubtreeIfNeeded()
        (contentView as? WorkshopPlayerNSView)?.refreshViewport()
        if mode != .interacting {
            makeFirstResponder(nil)
            if isKeyWindow { resignKey() }
        }
    }
}

@MainActor
final class WallpaperInteractionHUD {
    private var panel: NSPanel?

    func show(title: String, screen: NSScreen, onExit: @escaping () -> Void) {
        dismiss()
        let size = NSSize(width: 400, height: 56)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: InteractionBar(title: title, onExit: onExit))
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - size.width - 20,
                                     y: screen.visibleFrame.maxY - size.height - 16))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}

private struct InteractionBar: View {
    let title: String
    let onExit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.point.up.left.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("网页壁纸交互中").font(.caption.weight(.semibold))
                Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("退出交互 · Esc", action: onExit).controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// 网页壁纸的交互按钮：点击展开菜单，进入 / 退出交互，或选择在桌面上直接操作的方式
struct WebWallpaperInteractionButton: View {
    @ObservedObject private var controller = LiveWallpaperController.shared
    @AppStorage(DesktopSettings.webDesktopInput) private var desktopMode: WebDesktopInputMode = .off
    let item: WorkshopItem

    private var isCurrent: Bool { controller.currentURL?.standardizedFileURL == item.localFolder?.standardizedFileURL }
    private var isInteracting: Bool { controller.isInteracting && isCurrent }
    /// 正在桌面上播放、且不用进入交互就能直接操作
    private var isLiveOnDesktop: Bool { isCurrent && desktopMode != .off }

    var body: some View {
        Menu {
            Button {
                if isInteracting { controller.endInteraction() } else { controller.beginInteraction(with: item) }
            } label: {
                if isInteracting {
                    Label("退出交互（Esc）", systemImage: "xmark.circle")
                } else {
                    Label(isCurrent ? "进入交互（可用键盘）" : "设为壁纸并进入交互", systemImage: "keyboard")
                }
            }
            Divider()
            Picker("在桌面上直接操作", selection: $desktopMode) {
                ForEach(WebDesktopInputMode.allCases) { mode in
                    Text(mode.shortTitle).tag(mode)
                }
            }
            .pickerStyle(.inline)
            Divider()
            SettingsLink { Text("交互设置…") }
        } label: {
            CircleIconLabel(systemImage: isInteracting ? "cursorarrow.rays" : "cursorarrow.click.2",
                            tint: isInteracting || isLiveOnDesktop ? .accentColor : .primary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .accessibilityLabel("网页壁纸交互")
        .accessibilityValue(isInteracting ? "交互中" : desktopMode.shortTitle)
    }

    private var help: String {
        if isInteracting { return "交互中：点击、拖拽、滚轮和键盘都会交给壁纸，Esc 退出" }
        switch desktopMode {
        case .off: return "网页壁纸交互"
        case .forward: return "网页壁纸交互：点桌面空白处即可操作"
        case .direct: return "网页壁纸交互：壁纸直接接收鼠标"
        }
    }
}
