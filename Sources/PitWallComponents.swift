import SwiftUI

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
    var active: Bool
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(PW.well)
            content
            CornerBrackets()
                .stroke(active ? PW.green : PW.bracketIdle, lineWidth: 2)
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
            .pointerStyle(isEnabled ? .link : nil)
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
            .pointerStyle(isEnabled ? .link : nil)
    }
}

/// Text field drawn as a dark input well.
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
    @FocusState private var focused: Bool

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
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(font)
                    .foregroundStyle(color)
                    .multilineTextAlignment(alignment)
                    .focused($focused)
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
                .strokeBorder(focused ? PW.purple : PW.inputBorder, lineWidth: focused ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}
