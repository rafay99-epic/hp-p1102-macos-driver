import AppKit
import PDFKit

/// Manual two-sided printing. The P1102 has no duplexer, so pass 1 prints the
/// odd pages, the user reloads the stack, and pass 2 prints the even pages.
public enum Duplex {
    /// How this printer stacks and feeds paper. Defaults are right for the
    /// P1102 (face-down output, feeds from the top of the stack); the
    /// calibration sheet corrects them on other setups.
    public struct Settings: Codable, Equatable, Sendable {
        public var reverseEven = true
        public var printedSideUp = false
        public var rotateEven = false
        public init() {}

        static let key = "duplex.settings"
        public static func load() -> Settings {
            UserDefaults.standard.data(forKey: key)
                .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        }
        public func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key) }

        public var reloadSteps: [String] {
            ["Take the stack out of the output tray. Keep the sheets in the order they came out.",
             printedSideUp
                ? "Put it in the input tray with the printed side facing up."
                : "Put it in the input tray with the printed side facing down, the way it lay in the output tray."]
        }

        public enum Order: CaseIterable { case correct, swapped, overprinted }

        /// Applies the answer to "what is on the back of page 1?" from the calibration sheet.
        public mutating func calibrate(order: Order, upsideDown: Bool) {
            switch order {
            case .correct: break
            case .swapped: reverseEven.toggle()
            case .overprinted: printedSideUp.toggle(); reverseEven.toggle()
            }
            if upsideDown { rotateEven.toggle() }
        }
    }

    /// Page order for both passes, zero-based. nil is a blank back for the
    /// last sheet when the page count is odd.
    public static func plan(pageCount n: Int, reverseEven: Bool) -> (odd: [Int], even: [Int?]) {
        let odd = Array(stride(from: 0, to: n, by: 2))
        var even: [Int?] = Array(stride(from: 1, to: n, by: 2))
        if n > 1, n % 2 == 1 { even.append(nil) }
        return (odd, reverseEven ? even.reversed() : even)
    }

    /// Writes the two pass PDFs. `even` is nil for a one-page document.
    public static func split(_ source: URL, settings: Settings, into dir: URL) throws -> (odd: URL, even: URL?, sheets: Int) {
        guard let doc = PDFDocument(url: source), doc.pageCount > 0 else {
            throw CupsError("Can't read \(source.lastPathComponent) as a PDF")
        }
        let p = plan(pageCount: doc.pageCount, reverseEven: settings.reverseEven)
        let base = source.deletingPathExtension().lastPathComponent
        let odd = PDFDocument(), even = PDFDocument()
        for i in p.odd { odd.insert(doc.page(at: i)!.copy() as! PDFPage, at: odd.pageCount) }
        for i in p.even {
            let page: PDFPage
            if let i {
                page = doc.page(at: i)!.copy() as! PDFPage
            } else {
                page = PDFPage()
                page.setBounds(doc.page(at: 0)!.bounds(for: .mediaBox), for: .mediaBox)
            }
            if settings.rotateEven { page.rotation = (page.rotation + 180) % 360 }
            even.insert(page, at: even.pageCount)
        }
        let oddURL = dir.appendingPathComponent("\(base) (odd pages).pdf")
        let evenURL = dir.appendingPathComponent("\(base) (even pages).pdf")
        guard odd.write(to: oddURL), p.even.isEmpty || even.write(to: evenURL) else {
            throw CupsError("Couldn't write the split PDFs")
        }
        return (oddURL, p.even.isEmpty ? nil : evenURL, p.odd.count)
    }

    /// Four numbered pages with an arrow at the top, for working out how this
    /// printer feeds paper back in.
    public static func calibrationSheet(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("Two-sided calibration.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CupsError("Can't create calibration PDF") }
        for n in 1...4 {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let big: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 300)]
            let small: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 28)]
            ("↑ TOP" as NSString).draw(at: CGPoint(x: 230, y: 760), withAttributes: small)
            ("\(n)" as NSString).draw(at: CGPoint(x: 210, y: 300), withAttributes: big)
            NSGraphicsContext.current = nil
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }
}
