import AppKit

/// 18pt 的太阳与沙丘线条图标，作为模板自动适配菜单栏的深浅色。
enum StatusBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let frame = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 2.5, width: 15, height: 13), xRadius: 3, yRadius: 3)
            frame.lineWidth = 1.2
            frame.stroke()
            NSBezierPath(ovalIn: NSRect(x: 10.6, y: 10.4, width: 2.8, height: 2.8)).fill()
            let dune = NSBezierPath()
            dune.move(to: NSPoint(x: 3.5, y: 6))
            dune.curve(to: NSPoint(x: 8, y: 8), controlPoint1: NSPoint(x: 5, y: 6), controlPoint2: NSPoint(x: 6.3, y: 8.8))
            dune.curve(to: NSPoint(x: 14.5, y: 6.2), controlPoint1: NSPoint(x: 10.5, y: 6.7), controlPoint2: NSPoint(x: 12.5, y: 4.8))
            dune.lineWidth = 1.3
            dune.lineCapStyle = .round
            dune.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Scena"
        return image
    }()
}
