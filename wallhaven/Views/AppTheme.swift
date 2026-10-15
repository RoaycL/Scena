import AppKit
import SwiftUI

/// 只控制窗口内容，不修改 NSApplication 的外观，应用图标始终由系统决定。
enum AppTheme: String, CaseIterable, Identifiable {
    case system, day, night

    static let storageKey = "ui.theme"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "跟随系统"
        case .day: "日间"
        case .night: "夜间"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .day: .light
        case .night: .dark
        }
    }
}

/// 玻璃、遮罩和文字使用同一组语义颜色，壁纸本身不受主题影响。
struct ThemePalette {
    let scheme: ColorScheme
    var isDay: Bool { scheme == .light }
    var scrim: Color { isDay ? .white : .black }
    /// 玻璃面板的着色：保留透明感，背景只是隐约透出，文字仍然清楚
    var panel: Color { isDay ? .white.opacity(0.42) : Color(red: 0.07, green: 0.09, blue: 0.13).opacity(0.52) }
    var border: Color { isDay ? .white.opacity(0.6) : .white.opacity(0.13) }
    var selection: Color { isDay ? .accentColor.opacity(0.13) : .white.opacity(0.18) }
    var shadow: Color { .black.opacity(isDay ? 0.12 : 0.35) }
    /// 主按钮（设为壁纸、播放）和选中的筛选项：夜间白底黑字，日间强调色底白字
    var primaryFill: Color { isDay ? .accentColor : .white }
    var primaryText: Color { isDay ? .white : .black }
    /// 主按钮上的转圈：macOS 的转圈不认 tint，只能通过外观让它与底色形成对比
    var primarySpinnerScheme: ColorScheme { isDay ? .dark : .light }
}

private struct ScenaThemeScope: ViewModifier {
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system
    let transparentWindow: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if transparentWindow {
            content
                .preferredColorScheme(theme.colorScheme)
                .background(TransparentWindow())
        } else {
            content.preferredColorScheme(theme.colorScheme)
        }
    }
}

extension View {
    /// transparentWindow：窗口底色透明，让内容里的原生磨砂透出桌面。只给自己铺了磨砂背景的窗口打开，
    /// 否则没有背景的区域会直接露出桌面
    func scenaTheme(transparentWindow: Bool = true) -> some View { modifier(ScenaThemeScope(transparentWindow: transparentWindow)) }
}

/// 保留窗口的系统外观继承，仅使窗口底色透明，供原生磨砂材质透出桌面。
private struct TransparentWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.configureWindow() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configureWindow() }
        func configureWindow() {
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }
}

/// 跟随窗口内容主题的原生磨砂背景，主窗口、设置和下载窗口共用。
struct ScenaWindowGlass: NSViewRepresentable {
    @Environment(\.colorScheme) private var scheme
    /// 默认偏实；设置页这类以文字为主、背景简单的窗口可以用更通透的材质（如 .popover）
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.appearance = NSAppearance(named: scheme == .light ? .vibrantLight : .vibrantDark)
    }
}


/// 关于页也按应用级系统外观绘制图标，避免手动窗口主题影响图标的日夜变体。
struct SystemApplicationIcon: NSViewRepresentable {
    func makeNSView(context: Context) -> NSImageView {
        let view = FittingImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) { context.coordinator.refresh() }
    func makeCoordinator() -> Coordinator { Coordinator() }

    /// NSImageView 默认把图标原图尺寸（可达 1024pt）当作固有尺寸，SwiftUI 给的 64×64 框装不下，图标会溢出错位；
    /// 不报告固有尺寸，图标就严格缩放在给定的框里
    final class FittingImageView: NSImageView {
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    }

    final class Coordinator {
        private weak var view: NSImageView?
        private var appearanceObservation: NSKeyValueObservation?

        func attach(_ view: NSImageView) {
            self.view = view
            appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            refresh()
        }

        func refresh() {
            view?.appearance = NSApp.effectiveAppearance
            view?.image = NSApp.applicationIconImage
        }
    }
}
