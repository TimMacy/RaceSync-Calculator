import SwiftUI
import CoreText

// MARK: - Pit Wall theme -
// Timing-screen palette: purple = result, green = locked feed, yellow = action, red = lights out.

enum PW {
    // Surfaces
    static let background   = Color(hex: 0x0B0D10)
    static let header       = Color(hex: 0x0E1014)
    static let card         = Color(hex: 0x12151A)
    static let well         = Color(hex: 0x07080B)
    static let segmentOn    = Color(hex: 0x232832)

    // Lines
    static let divider      = Color(hex: 0x1E232B)
    static let cardBorder   = Color(hex: 0x222730)
    static let inputBorder  = Color(hex: 0x2A303A)
    static let dashedBorder = Color(hex: 0x3A414D)
    static let bracketIdle  = Color(hex: 0x3A414D)

    // Text
    static let text         = Color(hex: 0xECEEF1)
    static let soft         = Color(hex: 0xC6CBD3)
    static let muted        = Color(hex: 0x9099A8)

    // Accents
    static let green        = Color(hex: 0x3DDC84)
    static let greenSoft    = Color(hex: 0x9FD9B7)
    static let greenBG      = Color(hex: 0x10261A)
    static let greenBorder  = Color(hex: 0x1B4A30)
    static let yellow       = Color(hex: 0xFFD23F)
    static let yellowBG     = Color(hex: 0x2A2410)
    static let purple       = Color(hex: 0xB388FF)
    static let purpleBorder = Color(hex: 0x2E2546)
    static let purpleBG     = Color(hex: 0x1A1626)
    static let purpleEdge   = Color(hex: 0x3A3158)
    static let red          = Color(hex: 0xFF4B4B)
    static let redBG        = Color(hex: 0x2A1214)
    static let lightsButton = Color(hex: 0xE10600)

    // Type: the mockup's fonts, bundled in Fonts/ (SIL Open Font License)
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .custom(weight == .bold || weight == .heavy || weight == .black ? "JetBrainsMono-Bold" : "JetBrainsMono-Medium",
                fixedSize: size)
    }

    /// Saira Condensed Bold; use `.pwDisplay(_:)` to also get the mockup's slant.
    static func display(_ size: CGFloat) -> Font {
        .custom("SairaCondensed-Bold", fixedSize: size)
    }

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// Registers the bundled fonts for this app only. Call once at launch.
enum PWFonts {
    static func register() {
        for name in ["SairaCondensed-Bold", "JetBrainsMono-Medium", "JetBrainsMono-Bold"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf")
                    ?? Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") else {
                print("Font missing from bundle: \(name)")
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

/// Slanted like the mockup (Saira Condensed has no italic, so the browser slants it).
struct Oblique: GeometryEffect {
    var slant: CGFloat = 0.2

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(a: 1, b: 0, c: -slant, d: 1, tx: slant * size.height / 2, ty: 0))
    }
}

extension View {
    func pwDisplay(_ size: CGFloat) -> some View {
        font(PW.display(size)).modifier(Oblique())
    }
}
