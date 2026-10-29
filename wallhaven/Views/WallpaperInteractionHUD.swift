import AppKit
import SwiftUI

/// 只有显式进入网页交互时，桌面窗口才接受输入并允许成为键盘窗口。
final class WallpaperDesktopWindow: NSWindow {
    private(set) var allowsInteraction = false
    /// Finder 的桌面图标窗口可令底层壁纸被系统标为遮挡。保留真实值供宿主决定是否暂停。
    var systemOcclusionState: NSWindow.OcclusionState { super.occlusionState }
    /// WKWebView 除了定时器，还会因窗口遮挡停止 CSS / 视频合成。播放暂停由宿主统一管理。
    override var occlusionState: NSWindow.OcclusionState {
        isVisible ? super.occlusionState.union(.visible) : super.occlusionState
    }
    override var canBecomeKey: Bool { allowsInteraction }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func setInteractionEnabled(_ enabled: Bool, desktopLevel: NSWindow.Level) {
        let targetFrame = screen?.frame ?? frame
        allowsInteraction = enabled
        ignoresMouseEvents = !enabled
        acceptsMouseMovedEvents = enabled
        level = enabled ? .normal : desktopLevel
        (contentView as? WorkshopPlayerNSView)?.setInteractionEnabled(enabled)
        setFrame(targetFrame, display: true)
        contentView?.frame = NSRect(origin: .zero, size: targetFrame.size)
        contentView?.needsLayout = true
        contentView?.layoutSubtreeIfNeeded()
        (contentView as? WorkshopPlayerNSView)?.refreshViewport()
        if !enabled {
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

struct WebWallpaperInteractionButton: View {
    @ObservedObject private var controller = LiveWallpaperController.shared
    let item: WorkshopItem

    private var isCurrent: Bool { controller.currentURL?.standardizedFileURL == item.localFolder?.standardizedFileURL }

    var body: some View {
        CircleIconButton(systemImage: "hand.point.up.left", tint: controller.isInteracting && isCurrent ? .accentColor : .primary,
                         help: controller.isInteracting && isCurrent ? "退出网页交互（Esc）" : "网页壁纸交互：点击、拖拽、滚轮；Esc 退出") {
            if controller.isInteracting && isCurrent { controller.endInteraction() }
            else { controller.beginInteraction(with: item) }
        }
        .accessibilityLabel(controller.isInteracting && isCurrent ? "退出网页交互" : "进入网页壁纸交互")
    }
}
