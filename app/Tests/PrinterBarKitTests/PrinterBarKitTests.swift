import PDFKit
import XCTest
@testable import PrinterBarKit

final class DuplexTests: XCTestCase {
    func testEvenCountReversesBacks() {
        let p = Duplex.plan(pageCount: 6, reverseEven: true)
        XCTAssertEqual(p.odd, [0, 2, 4])
        XCTAssertEqual(p.even, [5, 3, 1])
    }

    func testOddCountPadsLastSheetWithBlank() {
        // 5 pages = 3 sheets; the last sheet's back is blank, and it comes out first.
        let p = Duplex.plan(pageCount: 5, reverseEven: true)
        XCTAssertEqual(p.odd, [0, 2, 4])
        XCTAssertEqual(p.even, [nil, 3, 1])
        XCTAssertEqual(Duplex.plan(pageCount: 5, reverseEven: false).even, [1, 3, nil])
    }

    func testSinglePageHasNoSecondPass() {
        XCTAssertEqual(Duplex.plan(pageCount: 1, reverseEven: true).even, [])
    }

    func testCalibrationOverprintFlipsSideAndOrder() {
        var s = Duplex.Settings()
        s.calibrate(order: .overprinted, upsideDown: true)
        XCTAssertTrue(s.printedSideUp)
        XCTAssertFalse(s.reverseEven)
        XCTAssertTrue(s.rotateEven)
    }

    func testSplitWritesPassesWithRotation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let doc = PDFDocument()
        for _ in 0..<3 { doc.insert(PDFPage(), at: doc.pageCount) }
        let src = dir.appendingPathComponent("doc.pdf")
        XCTAssertTrue(doc.write(to: src))

        var settings = Duplex.Settings()
        settings.rotateEven = true
        let out = try Duplex.split(src, settings: settings, into: dir)
        XCTAssertEqual(PDFDocument(url: out.odd)?.pageCount, 2)
        let even = try XCTUnwrap(out.even.flatMap(PDFDocument.init(url:)))
        XCTAssertEqual(even.pageCount, 2)
        XCTAssertEqual(even.page(at: 0)?.rotation, 180)
    }
}
