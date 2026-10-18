import AppKit
import CoreText
import SwiftUI

// Rocky's look: Geist, near-black ink on white, light lines, black 8 pt buttons, a gold accent.
enum Ink {
    static let primary = Color(hex: 0x17181B)
    static let secondary = Color(hex: 0x3A3C41)
    static let muted = Color(hex: 0x6B6E76)
    static let faint = Color(hex: 0x9A9DA4)
    static let line = Color(hex: 0xE6E7EA)
    static let field = Color(hex: 0xF6F6F7)
    static let gold = Color(hex: 0xFFD66B)
    static let red = Color(hex: 0xE5484D)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

enum Fonts {
    private static let registered: Void = {
        for name in ["Geist", "GeistMono"] {
            if let url = Bundle.main.resourceURL?.appendingPathComponent("Fonts/\(name).woff2") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()
    static func register() { _ = registered }
}

extension Font {
    static func geist(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Fonts.register()
        let name: String
        switch weight {
        case .medium: name = "Geist-Medium"
        case .semibold, .bold: name = "Geist-SemiBold"
        default: name = "Geist-Regular"
        }
        return .custom(name, fixedSize: size)
    }

    static func geistMono(_ size: CGFloat) -> Font {
        Fonts.register()
        return .custom("GeistMono-Regular", fixedSize: size)
    }
}

struct DarkButton: ButtonStyle {
    var height: CGFloat = 44
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(15, .medium))
            .frame(maxWidth: .infinity, minHeight: height)
            .foregroundStyle(Color.white)
            .background(RoundedRectangle(cornerRadius: 8).fill(Ink.primary))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

struct SmallButton: ButtonStyle {
    var dark = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(12))
            .foregroundStyle(dark ? Color.white : Ink.primary)
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(dark ? Ink.primary : Color.white))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(dark ? Ink.primary : Color(hex: 0xE1E2E5), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

/// Start and done sounds: macOS's Tink and Glass with everything above 1.5 kHz cut (Resources/Sounds).
@MainActor
enum Sounds {
    private static var cache: [String: NSSound] = [:]
    static func play(_ name: String) {
        guard Prefs.sounds else { return }
        if cache[name] == nil, let url = Bundle.main.url(forResource: name, withExtension: "caf", subdirectory: "Sounds") {
            cache[name] = NSSound(contentsOf: url, byReference: true)
        }
        cache[name]?.stop()
        cache[name]?.play()
    }
}
