import SwiftUI

/// Shared look for every screen: true black, white text, dense rows,
/// hover highlight instead of button chrome.
enum Ink {
    static let dim = Color(white: 0.62)
    static let line = Color(white: 0.22)
    static let hover = Color(white: 0.12)
    static let bad = Color(red: 1, green: 0.42, blue: 0.42)
}

struct Row<Trailing: View>: View {
    var title: String
    var bold = false
    var color: Color = .primary
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Text(title).fontWeight(bold ? .semibold : .regular).foregroundStyle(color).lineLimit(1)
            Spacer(minLength: 8)
            trailing.foregroundStyle(Ink.dim).monospacedDigit().lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 24)
    }
}

extension Row where Trailing == Text {
    init(_ title: String, _ detail: String = "", bold: Bool = false, color: Color = .primary) {
        self.init(title: title, bold: bold, color: color) { Text(detail) }
    }
}

/// A full-width row that acts as a button.
struct Action: View {
    var title: String
    var detail = ""
    var key: KeyEquivalent?
    var modifiers: EventModifiers = .command
    var prominent = false
    var action: () -> Void

    init(_ title: String, _ detail: String = "", key: KeyEquivalent? = nil, modifiers: EventModifiers = .command,
         prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.detail = detail; self.key = key; self.modifiers = modifiers
        self.prominent = prominent; self.action = action
    }

    var body: some View {
        let button = Button(action: action) {
            Row(title, detail, bold: prominent)
        }
        .buttonStyle(Hover(prominent: prominent))
        if let key { button.keyboardShortcut(key, modifiers: modifiers) } else { button }
    }
}

/// Small inline text button used inside row trailing content.
struct TextLink: View {
    var title: String
    var color: Color = Ink.dim
    var action: () -> Void
    init(_ title: String, color: Color = Ink.dim, action: @escaping () -> Void) {
        self.title = title; self.color = color; self.action = action
    }
    var body: some View {
        Button(title, action: action).buttonStyle(.plain).foregroundStyle(color)
    }
}

struct Hover: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View { HoverBody(configuration: configuration, prominent: prominent) }

    private struct HoverBody: View {
        let configuration: Configuration
        let prominent: Bool
        @State private var hovering = false
        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(hovering || prominent || configuration.isPressed ? Ink.hover : .clear)
                    .padding(.horizontal, 5))
                .onHover { hovering = $0 }
        }
    }
}

struct Sep: View {
    var body: some View { Rectangle().fill(Ink.line).frame(height: 1).padding(.vertical, 5) }
}

struct SectionLabel: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(Ink.dim)
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Note: View {
    var text: String
    var color: Color = Ink.dim
    init(_ text: String, color: Color = Ink.dim) { self.text = text; self.color = color }
    var body: some View {
        Text(text).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Underlined text choices, e.g. A4 / Letter / Legal.
struct Choice<T: Hashable>: View {
    var options: [T]
    @Binding var selection: T
    var label: (T) -> String

    var body: some View {
        HStack(spacing: 12) {
            ForEach(options, id: \.self) { o in
                Button(label(o)) { selection = o }
                    .buttonStyle(.plain)
                    .foregroundStyle(o == selection ? Color.primary : Ink.dim)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(o == selection ? Color.primary : .clear).frame(height: 1).offset(y: 2)
                    }
            }
        }
    }
}

/// On/Off text toggle that matches the ledger rows.
struct OnOff: View {
    var title: String
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: { Row(title, isOn ? "On" : "Off") }.buttonStyle(Hover())
    }
}

/// Back arrow header for pushed screens.
struct Header<Trailing: View>: View {
    var title: String
    var back: () -> Void
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack {
            Button("‹ \(title)", action: back).buttonStyle(.plain).keyboardShortcut(.escape, modifiers: [])
            Spacer()
            trailing.foregroundStyle(Ink.dim)
        }
        .padding(.horizontal, 14).frame(minHeight: 24)
    }
}

extension Header where Trailing == EmptyView {
    init(_ title: String, back: @escaping () -> Void) { self.init(title: title, back: back) { EmptyView() } }
}

/// Page progress bar. Moves once per finished sheet; never animates.
struct Meter: View {
    var fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(white: 0.17))
                Rectangle().fill(Color.primary).frame(width: g.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 3).padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 6)
        .transaction { $0.animation = nil }
    }
}
