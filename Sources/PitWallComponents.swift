import SwiftUI
import AppKit

// MARK: - Pit Wall components -

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(PW.mono(11))
            .tracking(1.6)
            .foregroundStyle(PW.muted)
    }
}

struct SmallCaps: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(PW.mono(10))
            .tracking(1.4)
            .foregroundStyle(PW.muted)
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    let background: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(PW.mono(10, .bold))
                .tracking(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(background))
    }
}

struct FeedCard<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10).fill(PW.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PW.cardBorder))
    }
}

/// Dark capture well with viewfinder corner brackets.
struct Viewfinder<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(PW.well)
            content
            CornerBrackets()
                .stroke(PW.bracketIdle, lineWidth: 2)
                .padding(8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The captured region itself, as large as fits and centered, with the brackets around it.
struct CapturePreview: View {
    let image: CGImage

    var body: some View {
        Image(nsImage: image.nsImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                CornerBrackets()
                    .stroke(PW.green, lineWidth: 2)
                    .padding(-5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            )
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension CGImage {
    /// For showing a captured region in a SwiftUI `Image`.
    var nsImage: NSImage {
        NSImage(cgImage: self, size: NSSize(width: width, height: height))
    }
}

struct CornerBrackets: Shape {
    var length: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let l = min(length, rect.width / 2, rect.height / 2)
        // top-left
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + l))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
        // top-right
        p.move(to: CGPoint(x: rect.maxX - l, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
        // bottom-left
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY - l))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + l, y: rect.maxY))
        // bottom-right
        p.move(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - l))
        return p
    }
}

// MARK: Button styles

struct OutlineButtonStyle: ButtonStyle {
    var dashed = false
    var height: CGFloat = 32
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PW.ui(12, .medium))
            .foregroundStyle(PW.soft)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? PW.segmentOn : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(dashed ? PW.dashedBorder : PW.inputBorder,
                                  style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : []))
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct SolidButtonStyle: ButtonStyle {
    var fill: Color
    var foreground: Color
    var height: CGFloat = 54
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 10).fill(fill))
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

/// Text field drawn as a dark input well.
/// Pass `formatter` (with `nativeFont`) to use AppKit's own text field, which applies the
/// formatter on every key press, text and cursor together (Apple's custom-formatter approach).
struct WellField: View {
    let placeholder: String
    @Binding var text: String
    var font: Font
    var color: Color
    var alignment: TextAlignment = .leading
    var height: CGFloat
    var background: Color = PW.well
    var radius: CGFloat = 6
    var suffix: String? = nil
    var formatter: Formatter? = nil
    var nativeFont: NSFont? = nil
    @FocusState private var focused: Bool
    @State private var nativeFocused = false
    @State private var boxID = UUID()

    private var isActive: Bool { formatter == nil ? focused : nativeFocused }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                // Own placeholder, aligned like the typed text (the system prompt ignores centering).
                if text.isEmpty {
                    Text(placeholder)
                        .font(font)
                        .foregroundStyle(PW.muted.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
                        .allowsHitTesting(false)
                }
                if let formatter {
                    NativeTextField(text: $text,
                                    isFocused: $nativeFocused,
                                    formatter: formatter,
                                    font: nativeFont ?? .systemFont(ofSize: NSFont.systemFontSize),
                                    color: NSColor(color),
                                    alignment: alignment == .center ? .center : .left)
                } else {
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .font(font)
                        .foregroundStyle(color)
                        .multilineTextAlignment(alignment)
                        .focused($focused)
                }
            }
            if let suffix {
                Text(suffix).font(PW.mono(12)).foregroundStyle(PW.muted)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: radius).fill(background))
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(isActive ? PW.purple : PW.inputBorder, lineWidth: isActive ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if formatter == nil { focused = true } else { nativeFocused = true }
        }
        .background {
            // Tell ClickOutsideEndsEditing where this box is, so a click inside it doesn't deselect the field.
            GeometryReader { geometry in
                let box = geometry.frame(in: .global)
                Color.clear
                    .onAppear { ClickOutsideEndsEditing.fieldBoxes[boxID] = box }
                    .onChange(of: box) { _, new in ClickOutsideEndsEditing.fieldBoxes[boxID] = new }
                    .onDisappear { ClickOutsideEndsEditing.fieldBoxes[boxID] = nil }
            }
        }
    }
}

/// Borderless AppKit text field with a live formatter, styled by the surrounding well.
struct NativeTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let formatter: Formatter
    let font: NSFont
    let color: NSColor
    let alignment: NSTextAlignment

    func makeNSView(context: Context) -> FocusReportingTextField {
        let field = FocusReportingTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.isScrollable = true
        field.formatter = formatter
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: FocusReportingTextField, context: Context) {
        context.coordinator.parent = self
        field.font = font
        field.textColor = color
        field.alignment = alignment
        field.onFocusChange = { focused in
            if isFocused != focused { isFocused = focused }
        }
        let current = field.currentEditor()?.string ?? field.stringValue
        if current != text { field.stringValue = text }
        if isFocused && field.currentEditor() == nil {
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeTextField
        init(parent: NativeTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.currentEditor()?.string ?? field.stringValue
        }
    }
}

/// Opens the window with no text field selected.
/// AppKit makes the window's `initialFirstResponder` the first responder the first time the window is
/// placed onscreen. This view doesn't accept first responder, so the window becomes its own first
/// responder instead, the same as clicking the background (NSWindow.makeFirstResponder(_:)).
struct NoInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Anchor() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.initialFirstResponder == nil else { return }
            window.initialFirstResponder = self
        }

        /// Never the target of a click, so clicks reach the background behind it (which clears the focus).
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Clicking anywhere outside the text field being edited deselects it, in every window of the app.
/// A local event monitor sees each click before AppKit dispatches it (NSEvent.addLocalMonitorForEvents).
/// The text being edited lives in the window's field editor, whose delegate is the text field
/// (NSWindow.fieldEditor(_:for:)); a click outside that field makes the window its own first responder.
enum ClickOutsideEndsEditing {
    private static var monitor: Any?
    /// The boxes drawn around text fields (`WellField`), in SwiftUI's window coordinates (top-left origin).
    /// A click anywhere in a box counts as a click on its field, not outside it.
    static var fieldBoxes: [UUID: CGRect] = [:]

    /// Call once; later calls do nothing.
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            guard let window = event.window,
                  let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                  let field = editor.delegate as? NSTextField else { return event }
            let inField = field.bounds.contains(field.convert(event.locationInWindow, from: nil))
            if !inField && !isInOwnBox(event.locationInWindow, of: field, in: window) {
                window.makeFirstResponder(nil)
            }
            return event // the click itself still goes through
        }
    }

    /// Whether the click is inside the box drawn around `field` (not another field's box).
    private static func isInOwnBox(_ locationInWindow: NSPoint, of field: NSTextField, in window: NSWindow) -> Bool {
        guard let contentView = window.contentView else { return false }
        func topLeft(_ rect: NSRect) -> CGRect {
            var rect = contentView.convert(rect, from: nil)
            if !contentView.isFlipped { rect.origin.y = contentView.bounds.height - rect.maxY }
            return rect
        }
        let fieldRect = topLeft(field.convert(field.bounds, to: nil))
        let click = topLeft(NSRect(origin: locationInWindow, size: .zero)).origin
        guard let ownBox = fieldBoxes.values.first(where: { $0.contains(CGPoint(x: fieldRect.midX, y: fieldRect.midY)) }) else {
            return false
        }
        return ownBox.contains(click)
    }
}

/// Reports when it gains and loses keyboard focus, so the well can draw its border.
final class FocusReportingTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}