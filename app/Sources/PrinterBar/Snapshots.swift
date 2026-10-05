import AppKit
import PrinterBarKit
import SwiftUI

/// `PrinterBar --render-screens <dir>` renders every screen with sample data
/// to PNGs. Used for the README screenshots and for checking layout without
/// a printer.
@MainActor
enum Snapshots {
    static func render(to dir: String) {
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let now = Date.now
        func job(_ id: Int, _ name: String, _ state: Job.State, sheets: Int = 0, ago: Double = 0) -> Job {
            Job(id: id, name: name, state: state, sheetsDone: sheets, created: now - ago,
                completed: state.rawValue >= 7 ? now - ago : nil, reasons: [])
        }
        let printing = [job(41, "invoice.pdf", .processing, sheets: 1), job(42, "report.pdf", .pending), job(43, "notes.txt", .pending)]
        let done = [job(38, "lease.pdf", .completed, sheets: 4, ago: 3600), job(37, "Test page", .completed, sheets: 1, ago: 4000),
                    job(36, "slides.pdf", .aborted, ago: 5000)]
        let testPage = Bundle.main.url(forResource: "testpage-A4", withExtension: "pdf") ?? URL(fileURLWithPath: "/tmp/report.pdf")

        let shots: [(String, (AppModel) -> Void)] = [
            ("1-ready", { $0.done = done }),
            ("2-printing", { $0.active = printing; $0.totals = [41: 5, 42: 12] }),
            ("3-print-file", { $0.screen = .printFile([testPage]) }),
            ("4-attention", { $0.active = printing; $0.totals = [41: 5]
                $0.printer = PrinterStatus(state: .stopped, reasons: ["media-empty-error"], message: "") }),
            ("5-unplugged", { $0.connected = false; $0.active = Array(printing.dropFirst()) }),
            ("6-queue", { $0.active = printing; $0.done = done; $0.totals = [41: 5, 42: 12]; $0.screen = .queue }),
            ("7-settings", { $0.screen = .settings }),
            ("8-test-page", { $0.screen = .testPage }),
            ("9-two-sided", { $0.duplex = DuplexRun(name: "report.pdf", paper: "A4", sheets: 6, phase: .reload, calibrating: false)
                $0.screen = .duplex }),
            ("10-driver", { $0.screen = .driver }),
            ("11-driver-missing", { $0.driverFilesPresent = false; $0.printer = nil }),
        ]
        for (name, setup) in shots {
            let model = AppModel()
            model.connected = true
            model.driverFilesPresent = true
            model.printer = PrinterStatus(state: .idle, reasons: ["none"], message: "")
            setup(model)
            let renderer = ImageRenderer(content: RootView().environment(model))
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: out.appendingPathComponent("\(name).png"))
        }
        for icon in Icon.allCases {
            let img = icon.image
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 72, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 72, height: 72).fill()
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(x: 0, y: 0, width: 72, height: 72))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("icon-\(icon).png"))
        }
    }
}
