// Renders the installer window's background (720 x 426 pt, @1x and @2x) for scripts/release.sh.
// The gold trail is cut from Resources/dmg/trail-gpt-image-2.png (OpenAI gpt-image-2) and set on pure white between
// where Finder draws the app (x 180) and Applications (x 540); the words are drawn here in Geist.
// Usage: swift scripts/dmg/background.swift <out dir>
import AppKit
import CoreText

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let out = URL(fileURLWithPath: CommandLine.arguments[1])
for f in ["Geist"] { CTFontManagerRegisterFontsForURL(root.appendingPathComponent("Resources/Fonts/\(f).woff2") as CFURL, .process, nil) }

let W = 720.0, H = 426.0, iconY = 200.0          // icon centres, top-left origin, as in the dmgbuild settings
let ink = NSColor(srgbRed: 0x17/255, green: 0x18/255, blue: 0x1B/255, alpha: 1)
let muted = NSColor(srgbRed: 0x6B/255, green: 0x6E/255, blue: 0x76/255, alpha: 1)
let gold = (r: 0xFF/255.0, g: 0xD6/255.0, b: 0x6B/255.0)

/// The trail as a gold layer whose alpha is how far each pixel is from white (blue channel: gold has little blue).
func trail() -> CGImage {
    let src = NSImage(contentsOf: root.appendingPathComponent("Resources/dmg/trail-gpt-image-2.png"))!
        .cgImage(forProposedRect: nil, context: nil, hints: nil)!
    // The dotted path sits in this box of the 1536 x 1024 source.
    let box = CGRect(x: 120, y: 390, width: 1300, height: 200)
    let cut = src.cropping(to: box)!
    let w = cut.width, h = cut.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cut, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
    for i in 0..<(w * h) {
        let b = Double(p[i * 4 + 2]) / 255
        let a = pow(max(0, min(1, (1 - b) / (1 - gold.b) * 2.0)), 0.5)
        let alpha = a < 0.25 ? 0 : a
        p[i * 4] = UInt8(gold.r * alpha * 255); p[i * 4 + 1] = UInt8(gold.g * alpha * 255)
        p[i * 4 + 2] = UInt8(gold.b * alpha * 255); p[i * 4 + 3] = UInt8(alpha * 255)
    }
    return ctx.makeImage()!
}

func render(scale s: Double) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * s), pixelsHigh: Int(H * s), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()

    // The trail between the two icons (icons are 112 pt; leave 18 pt on each side).
    let t = trail(), tw = 540.0 - 180.0 - 112.0 - 36.0, th = tw * Double(t.height) / Double(t.width)
    let cg = NSGraphicsContext.current!.cgContext
    cg.interpolationQuality = .high
    cg.draw(t, in: CGRect(x: 180 + 56 + 18, y: H - iconY - th / 2 + 4, width: tw, height: th))

    func text(_ s: String, _ font: NSFont, _ color: NSColor, x: Double, top: Double, align: NSTextAlignment) {
        let para = NSMutableParagraphStyle(); para.alignment = align
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para, .kern: -0.1]
        let size = (s as NSString).size(withAttributes: attr)
        let x0 = align == .center ? x - size.width / 2 : align == .right ? x - size.width : x
        (s as NSString).draw(at: NSPoint(x: x0, y: H - top - size.height), withAttributes: attr)
    }
    let geist = { (size: Double, weight: String) in NSFont(name: "Geist-\(weight)", size: size) ?? .systemFont(ofSize: size) }
    text("Drag Point and Yap into Applications", geist(17, "Medium"), ink, x: W / 2, top: 62, align: .center)
    text("Then open it from Applications.", geist(13, "Regular"), muted, x: W / 2, top: 88, align: .center)
    text("pointandyap.com", geist(12, "Regular"), muted, x: 32, top: H - 40, align: .left)
    text("Free and open source", geist(12, "Regular"), muted, x: W - 32, top: H - 40, align: .right)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (s, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
    try render(scale: s).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
print("wrote \(out.path)/background.png and background@2x.png")
