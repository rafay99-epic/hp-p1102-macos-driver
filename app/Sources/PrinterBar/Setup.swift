import AppKit
import PDFKit
import PrinterBarKit
import UniformTypeIdentifiers

/// Driver install checks and getting files to the printer.
enum Setup {
    static var driverFilesPresent: Bool {
        [Driver.encoder, Driver.filter, Driver.ppd].allSatisfy(exists)
    }

    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// The PPD's *FileVersion, shown in Settings.
    static var driverVersion: String? {
        guard let text = try? String(contentsOfFile: Driver.ppd, encoding: .isoLatin1),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("*FileVersion:") }) else { return nil }
        return line.split(separator: "\"").dropFirst().first.map(String.init)
    }

    /// Runs the driver/install.sh bundled in the app with an admin password prompt.
    static func installDriver() throws {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("driver") else { return }
        let args = ["install.sh", "foo2zjs", "rastertozjs", "HP-LaserJet-P1102.ppd"]
            .map { "'" + dir.appendingPathComponent($0).path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        let source = "do shell script \"\(args.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            throw CupsError(error[NSAppleScript.errorMessage] as? String ?? "Install failed")
        }
    }

    /// CUPS on macOS converts these itself.
    static func printsDirectly(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return [UTType.pdf, .image, .plainText].contains { type.conforms(to: $0) }
    }

    static func pageCount(_ url: URL) -> Int? {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
            return PDFDocument(url: url)?.pageCount
        }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true ? 1 : nil
    }

    /// Asks the file's own app (Word, PowerPoint, Pages...) to print it to the
    /// default printer, which PrinterBar keeps set to the P1102. Returns the
    /// app name, or nil after falling back to just opening the file.
    static func handOff(_ url: URL) -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"\(esc(app.path))\" to print POSIX file \"\(esc(url.path))\"")?
            .executeAndReturnError(&error)
        if error == nil { return app.deletingPathExtension().lastPathComponent }
        NSWorkspace.shared.open(url)
        return nil
    }
}
