import AppKit

/// 18pt 菜单栏图标：两张交叠的圆角卡片（前一张实心，后一张只露出描边的一角），
/// 作为模板图片自动适配菜单栏的深浅色。
enum StatusBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let back = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 5, width: 11.25, height: 11.25), xRadius: 3.2, yRadius: 3.2)
            back.lineWidth = 1.5
            back.stroke()
            // 前一张卡片周围留一圈空隙，把后面的描边断开
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: NSRect(x: 4, y: 0.75, width: 13.25, height: 13.25), xRadius: 4, yRadius: 4).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSBezierPath(roundedRect: NSRect(x: 5, y: 1.75, width: 11.25, height: 11.25), xRadius: 3.2, yRadius: 3.2).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Scena"
        return image
    }()
}
