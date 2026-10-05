import PDFKit
import PrinterBarKit
import SwiftUI
import UniformTypeIdentifiers

/// Open panels for Print File and Print Two-Sided.
@MainActor
enum Pick {
    static func files(_ model: AppModel) {
        let urls = run(types: nil, multiple: true)
        if !urls.isEmpty { model.screen = .printFile(urls) }
        model.showPopover()
    }

    static func duplex(_ model: AppModel) {
        if let url = run(types: [.pdf], multiple: false).first { model.startDuplex(url, paper: model.defaults.paper) }
        model.showPopover()
    }

    private static func run(types: [UTType]?, multiple: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        if let types { panel.allowedContentTypes = types }
        NSApp.activate()
        return panel.runModal() == .OK ? panel.urls : []
    }
}

struct PrintFileView: View {
    @Environment(AppModel.self) private var model
    let urls: [URL]
    @State private var options = AppModel.PrintOptions()
    @State private var allPages = true
    @State private var twoSided = false

    private var direct: [URL] { urls.filter(Setup.printsDirectly) }
    private var handOff: [URL] { urls.filter { !Setup.printsDirectly($0) } }
    private var pages: Int? {
        let counts = direct.map(Setup.pageCount)
        return counts.contains(where: { $0 == nil }) ? nil : counts.compactMap { $0 }.reduce(0, +)
    }
    private var single: URL? { urls.count == 1 ? urls[0] : nil }
    private var isPDF: Bool { single.map { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .pdf) == true } ?? false }

    var body: some View {
        Header("Print File") { model.screen = .main }
            .onAppear { options.paper = model.defaults.paper; options.tonerSave = model.defaults.tonerSave }
        Sep()
        Row(single?.lastPathComponent ?? "\(urls.count) files", pages.map { "\($0) page\($0 == 1 ? "" : "s")" } ?? "", bold: true)
        if !direct.isEmpty {
            if single != nil, !twoSided {
                Row(title: "Pages") {
                    HStack(spacing: 8) {
                        Choice(options: [true, false], selection: $allPages) { $0 ? "All" : "Range" }
                        if !allPages {
                            TextField("1-4, 7", text: $options.range).textFieldStyle(.plain).frame(width: 64)
                        }
                    }
                }
            }
            Row(title: "Paper") { Choice(options: Queue.papers, selection: $options.paper) { $0 } }
            if !twoSided {
                Row(title: "Copies") {
                    HStack(spacing: 8) {
                        TextLink("−") { options.copies = max(1, options.copies - 1) }
                        Text("\(options.copies)").foregroundStyle(Color.primary)
                        TextLink("+") { options.copies = min(99, options.copies + 1) }
                    }
                }
            }
            if isPDF { OnOff(title: "Two-sided (by hand)", isOn: $twoSided) }
            OnOff(title: "Toner save", isOn: $options.tonerSave)
            Sep()
            Action(printTitle, "↩", key: .return, modifiers: [], prominent: true) {
                if twoSided, let url = single { model.startDuplex(url, paper: options.paper) } else {
                    if allPages { options.range = "" }
                    model.print(urls, options)
                }
            }
        } else {
            Sep()
            Action("Print with \(appName)", "↩", key: .return, modifiers: [], prominent: true) { model.print(urls, options) }
        }
        if !handOff.isEmpty {
            Note("\(handOff.map(\.lastPathComponent).joined(separator: ", ")): handed to \(appName), which prints to the P1102.")
                .font(.system(size: 11.5))
        }
    }

    private var printTitle: String {
        if twoSided { return "Print Two-Sided" }
        guard allPages, let pages else { return "Print" }
        let n = pages * options.copies
        return "Print \(n) page\(n == 1 ? "" : "s")"
    }

    private var appName: String {
        handOff.first.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }?
            .deletingPathExtension().lastPathComponent ?? "its app"
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pickingType = false

    var body: some View {
        @Bindable var model = model
        Header("Settings") { model.screen = .main }
        SectionLabel("Defaults for every print, ⌘P too")
        Row(title: "Paper") { Choice(options: Queue.papers, selection: $model.defaults.paper) { $0 } }
        Action("Paper type", "\(model.defaults.mediaType) \(pickingType ? "⌄" : "›")") { pickingType.toggle() }
        if pickingType {
            ForEach(Queue.mediaTypes, id: \.self) { t in
                Action("   \(t)", t == model.defaults.mediaType ? "✓" : "") {
                    model.defaults.mediaType = t
                    pickingType = false
                }
            }
        }
        Row(title: "Density") { Choice(options: ["1", "2", "3", "4", "5"], selection: $model.defaults.density) { $0 } }
        OnOff(title: "Toner save", isOn: $model.defaults.tonerSave)
        SectionLabel("Behaviour")
        OnOff(title: "Open when the printer connects", isOn: $model.openOnConnect)
        OnOff(title: "Notify when a job finishes", isOn: $model.notifyFinish)
        OnOff(title: "Notify on problems", isOn: $model.notifyProblems)
        OnOff(title: "Make P1102 the default printer", isOn: $model.makeDefault)
        SectionLabel("Driver")
        Action(model.driverInstalled ? "Installed" + (Setup.driverVersion.map { ", version \($0)" } ?? "") : "Not installed", "Check ›") {
            model.screen = .driver
        }
        .onChange(of: model.defaults) { _, _ in model.saveDefaults() }
        .onChange(of: model.makeDefault) { _, on in if on { Queue.makeDefaultPrinter() } }
    }
}

struct TestPageView: View {
    @Environment(AppModel.self) private var model
    @State private var paper = "A4"

    var body: some View {
        Header("Test Page") { model.screen = .main }
        Sep()
        if let image = thumbnail {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(height: 150).frame(maxWidth: .infinity)
                .overlay(Rectangle().stroke(Color(white: 0.33)).frame(width: 150 * image.size.width / image.size.height))
                .padding(.vertical, 6)
        }
        Row(title: "Paper") { Choice(options: Queue.papers, selection: $paper) { $0 } }
        Note("Text sizes, gray ramp, line widths, and the edges of the printable area.")
        Sep()
        Action("Print Test Page", "↩", key: .return, modifiers: [], prominent: true) { model.printTestPage(paper: paper) }
            .onAppear { paper = model.defaults.paper }
    }

    private var thumbnail: NSImage? {
        Bundle.main.url(forResource: "testpage-\(paper)", withExtension: "pdf")
            .flatMap(PDFDocument.init(url:))?.page(at: 0)?.thumbnail(of: NSSize(width: 220, height: 300), for: .mediaBox)
    }
}

struct DuplexView: View {
    @Environment(AppModel.self) private var model
    @State private var order = Duplex.Settings.Order.correct
    @State private var upsideDown = false

    var body: some View {
        if let run = model.duplex {
            Header(title: "Two-Sided", back: { model.screen = .main }) { Text("\(run.name) · \(run.sheets) sheet\(run.sheets == 1 ? "" : "s")") }
            Sep()
            switch run.phase {
            case .printingFront:
                Step("1", "Printing the fronts…")
                Step("2", "Reload the stack", dim: true)
                Step("3", "Backs print", dim: true)
                Sep()
                Action("Cancel") { if let id = run.frontJob { Cups.cancel(id) }; model.duplex = nil; model.screen = .main }
            case .reload:
                Step("✓", "Fronts printed")
                ForEach(Array(Duplex.Settings.load().reloadSteps.enumerated()), id: \.offset) { i, s in
                    Step(i == 0 ? "2" : "", s)
                }
                Step("3", "Backs print", dim: true)
                Sep()
                Action("Continue", "↩", key: .return, modifiers: [], prominent: true) { model.printBacks() }
                Action("Cancel") { model.duplex = nil; model.screen = .main }
            case .printingBack:
                Step("✓", "Fronts printed")
                Step("✓", "Stack reloaded")
                Step("3", "Printing the backs…")
            case .calibrate:
                Note("Look at the sheet with 1 on it.")
                Row(title: "Back of page 1 shows") {
                    Choice(options: Duplex.Settings.Order.allCases, selection: $order) {
                        switch $0 { case .correct: "2"; case .swapped: "4"; case .overprinted: "blank" }
                    }
                }
                OnOff(title: "Back is upside down", isOn: $upsideDown)
                Sep()
                Action("Save", "↩", key: .return, modifiers: [], prominent: true) {
                    model.finishCalibration(order, upsideDown: upsideDown)
                }
            case .done:
                Step("✓", "Done. \(run.sheets) sheet\(run.sheets == 1 ? "" : "s") printed on both sides.")
                Sep()
                Action("Close", "↩", key: .return, modifiers: [], prominent: true) { model.duplex = nil; model.screen = .main }
            }
        } else {
            Header("Two-Sided") { model.screen = .main }
            Sep()
            Action("Choose a PDF…", "⌘O", key: "o", prominent: true) { Pick.duplex(model) }
            Action("Print calibration sheet", "›") { model.startDuplex(nil, paper: model.defaults.paper) }
            Note("First time? The calibration sheet works out how to reload paper on this printer.")
        }
    }
}

private struct Step: View {
    var mark: String
    var text: String
    var dim = false
    init(_ mark: String, _ text: String, dim: Bool = false) { self.mark = mark; self.text = text; self.dim = dim }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(mark).font(.system(size: 12, design: .monospaced)).frame(width: 16, alignment: .leading)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(dim ? Ink.dim : Color.primary)
        .padding(.horizontal, 14).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DriverView: View {
    @Environment(AppModel.self) private var model
    @State private var extras: [String] = []

    var body: some View {
        Header("Driver") { model.screen = .settings }
        Sep()
        check("Filter and encoder", ok: Setup.exists(Driver.filter) && Setup.exists(Driver.encoder), "/Library/Printers/HP-P1102")
        check("PPD", ok: Setup.exists(Driver.ppd), Setup.driverVersion.map { "v\($0)" } ?? "")
        check("Print queue", ok: model.printer != nil, Driver.queue)
        ForEach(extras, id: \.self) { q in
            Row(title: "✕ Extra queue \(q)", color: Ink.bad) {
                TextLink("Remove") { _ = Queue.remove(q); extras = Queue.extraQueues() }
            }
        }
        Sep()
        Action(model.driverInstalled ? "Repair" : "Install Driver", "asks for your password", prominent: true) {
            model.installDriver()
            extras = Queue.extraQueues()
        }
        .onAppear { extras = Queue.extraQueues() }
    }

    private func check(_ title: String, ok: Bool, _ detail: String) -> some View {
        Row("\(ok ? "✓" : "✕") \(title)", detail, color: ok ? .primary : Ink.bad)
    }
}
