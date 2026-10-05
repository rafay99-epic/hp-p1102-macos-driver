import PDFKit
import XCTest
@testable import PrinterBarKit

/// Runs against the real CUPS queue, so only in CI (which installs the
/// driver first). Locally it would pause a queue you might be printing on.
final class LiveQueueTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CI"] != nil, "CI only")
        try XCTSkipUnless(Cups.printer() != nil, "needs the \(Driver.queue) queue (sudo make install)")
        Queue.run("/usr/sbin/cupsdisable", Driver.queue)
    }

    override func tearDown() { Queue.enable() }

    func testJobLifecycle() throws {
        let pdf = FileManager.default.temporaryDirectory.appendingPathComponent("printerbar-test.pdf")
        let doc = PDFDocument()
        doc.insert(PDFPage(), at: 0)
        XCTAssertTrue(doc.write(to: pdf))

        let id = try Cups.submit(pdf, title: "PrinterBar test", options: ["PageSize": "A4"])
        XCTAssertEqual(Cups.printer()?.state, .stopped)
        XCTAssertEqual(state(id), .pending)

        XCTAssertTrue(Cups.hold(id))
        XCTAssertEqual(state(id), .held)
        XCTAssertTrue(Cups.release(id))
        XCTAssertEqual(state(id), .pending)
        XCTAssertTrue(Cups.printNext(id))

        XCTAssertTrue(Cups.cancel(id))
        XCTAssertNil(state(id))
        XCTAssertEqual(Cups.jobs(completed: true).first { $0.id == id }?.state, .canceled)
    }

    func testDefaultsRoundTrip() {
        let before = Queue.defaults()
        var changed = before
        changed.paper = "Legal"
        changed.density = "5"
        changed.tonerSave = true
        XCTAssertTrue(Queue.setDefaults(changed))
        XCTAssertEqual(Queue.defaults(), changed)
        XCTAssertTrue(Queue.setDefaults(before))
    }

    private func state(_ id: Int) -> Job.State? {
        Cups.jobs(completed: false).first { $0.id == id }?.state
    }
}
