import AppKit

/// Menu bar icons (icon set 1, "native printer"). Template images, so macOS
/// tints them for light and dark menu bars. States differ by shape, not color.
enum Icon: CaseIterable {
    case ready, printing, paused, attention, held

    /// Drawn once per state, not on every status change.
    var image: NSImage { Self.cache[self]! }
    private static let cache = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.draw()) })

    private func draw() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            paint()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "HP LaserJet P1102, \(self)"
        return img
    }

    private func paint() {
        let top = NSBezierPath(rect: NSRect(x: 5, y: 2, width: 8, height: 4))
        let body = NSBezierPath(roundedRect: NSRect(x: 2, y: 6, width: 14, height: 7), xRadius: 1.5, yRadius: 1.5)
        let paper = NSRect(x: 5, y: 11, width: 8, height: 5)
        [top, body].forEach { $0.lineWidth = 1.3 }

        switch self {
        case .ready, .printing:
            top.stroke()
            if self == .printing { body.fill() } else { body.stroke() }
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(rect: paper).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            let out = NSBezierPath(rect: paper)
            out.lineWidth = 1.3
            out.stroke()
            if self == .printing { line(7, 13.5, 11, 13.5, 1.2) }
        case .paused:
            body.stroke()
            line(7.5, 1.5, 7.5, 5.5, 1.7)
            line(10.5, 1.5, 10.5, 5.5, 1.7)
        case .attention:
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: 9, y: 2)); tri.line(to: NSPoint(x: 16.5, y: 15.5)); tri.line(to: NSPoint(x: 1.5, y: 15.5)); tri.close()
            tri.lineWidth = 1.3
            tri.stroke()
            line(9, 7, 9, 11, 1.7)
            line(9, 12.6, 9, 13.5, 1.7)
        case .held:
            for p in [top, body] { p.setLineDash([2, 1.6], count: 2, phase: 0); p.stroke() }
        }
    }

    private func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ w: CGFloat) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: x1, y: y1)); p.line(to: NSPoint(x: x2, y: y2))
        p.lineWidth = w
        p.stroke()
    }
}
