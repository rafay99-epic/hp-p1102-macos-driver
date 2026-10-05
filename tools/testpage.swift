// Writes a one-page test PDF.
// Usage: swift tools/testpage.swift out.pdf [A4|Letter|Legal]
import AppKit

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "testpage.pdf")
let sizes: [String: CGSize] = ["A4": .init(width: 595, height: 842),
                                "Letter": .init(width: 612, height: 792),
                                "Legal": .init(width: 612, height: 1008)]
let name = args.count > 2 ? args[2] : "A4"
guard let size = sizes[name] else { fatalError("unknown size \(name)") }
var box = CGRect(origin: .zero, size: size)

let ctx = CGContext(out as CFURL, mediaBox: &box, nil)!
ctx.beginPDFPage(nil)
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

let W = box.width, H = box.height, m: CGFloat = 12  // just inside the 11.52pt printable margin

func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, bold: Bool = false) {
    let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    (s as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: font])
}

ctx.setLineWidth(1)
ctx.stroke(CGRect(x: m, y: m, width: W - 2 * m, height: H - 2 * m))
for (cx, cy) in [(m, m), (W - m, m), (m, H - m), (W - m, H - m)] {
    ctx.move(to: CGPoint(x: cx - 8, y: cy)); ctx.addLine(to: CGPoint(x: cx + 8, y: cy))
    ctx.move(to: CGPoint(x: cx, y: cy - 8)); ctx.addLine(to: CGPoint(x: cx, y: cy + 8))
}
ctx.strokePath()

var y = H - 70
text("HP LaserJet P1102 on macOS, \(name)", 40, y, size: 24, bold: true); y -= 22
text("Quartz cgpdftoraster -> rastertozjs -> foo2zjs -z2 -> USB", 40, y, size: 11); y -= 14
text("Printed \(Date())", 40, y, size: 9); y -= 30

for size in [6, 8, 10, 12, 16, 22] as [CGFloat] {
    text("\(Int(size))pt  The quick brown fox jumps over the lazy dog 0123456789", 40, y, size: size)
    y -= size + 8
}
y -= 10

text("Gray ramp 0% to 100%", 40, y, size: 10, bold: true); y -= 40
for i in 0...10 {
    ctx.setFillColor(gray: 1 - CGFloat(i) / 10, alpha: 1)
    ctx.fill(CGRect(x: 40 + CGFloat(i) * 46, y: y, width: 44, height: 30))
    ctx.setFillColor(gray: 0, alpha: 1)
    text("\(i * 10)%", 46 + CGFloat(i) * 46, y - 12, size: 8)
}
y -= 30

let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                      colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray,
                      locations: [0, 1])!
ctx.saveGState()
ctx.clip(to: CGRect(x: 40, y: y - 30, width: 506, height: 24))
ctx.drawLinearGradient(grad, start: CGPoint(x: 40, y: 0), end: CGPoint(x: 546, y: 0), options: [])
ctx.restoreGState()
y -= 60

text("Line widths 0.12 / 0.25 / 0.5 / 1 / 2 / 4 pt", 40, y, size: 10, bold: true); y -= 14
ctx.setStrokeColor(gray: 0, alpha: 1)
for (i, w) in ([0.12, 0.25, 0.5, 1, 2, 4] as [CGFloat]).enumerated() {
    ctx.setLineWidth(w)
    ctx.move(to: CGPoint(x: 40, y: y - CGFloat(i) * 10)); ctx.addLine(to: CGPoint(x: 546, y: y - CGFloat(i) * 10))
    ctx.strokePath()
}
y -= 80

let c = CGPoint(x: 130, y: y - 80)
ctx.setFillColor(gray: 0, alpha: 1)
for k in stride(from: 0, to: 72, by: 2) {
    let a0 = CGFloat(k) * .pi / 36, a1 = CGFloat(k + 1) * .pi / 36
    ctx.move(to: c)
    ctx.addLine(to: CGPoint(x: c.x + 80 * cos(a0), y: c.y + 80 * sin(a0)))
    ctx.addLine(to: CGPoint(x: c.x + 80 * cos(a1), y: c.y + 80 * sin(a1)))
    ctx.closePath()
}
ctx.fillPath()

ctx.fill(CGRect(x: 260, y: y - 160, width: 120, height: 160))
text("Solid", 400, y - 20, size: 12, bold: true)
text("Corners should show + marks", 400, y - 40, size: 9)
text("on the printable border.", 400, y - 52, size: 9)

NSGraphicsContext.current = nil
ctx.endPDFPage()
ctx.closePDF()
print("wrote \(out.path)")
