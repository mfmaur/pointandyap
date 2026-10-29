import AppKit
import ApplicationServices

/// Reads the Accessibility element under a global point (top-left origin).
enum AXProbe {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func askForTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private static let system = AXUIElementCreateSystemWide()

    static func element(at p: CGPoint) -> (Element?, window: String?, url: String?) {
        guard trusted else { return (nil, nil, nil) }
        AXUIElementSetMessagingTimeout(system, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &hit) == .success, let el = hit else {
            return (nil, nil, nil)
        }
        return read(el)
    }

    /// A dragged area: the smallest element around it, named as itself but framed as the area.
    static func element(around r: CGRect) -> (Element?, window: String?, url: String?) {
        guard trusted else { return (nil, nil, nil) }
        AXUIElementSetMessagingTimeout(system, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(r.midX), Float(r.midY), &hit) == .success, var el = hit else {
            return (nil, nil, nil)
        }
        for _ in 0..<12 {
            if let f = frame(el), f.insetBy(dx: -2, dy: -2).contains(r) { break }
            guard let up = parent(of: el) else { break }
            el = up
        }
        var out = read(el)
        out.0?.frame = Rect(r)
        return out
    }

    /// The frame of the element under a point, for the box drawn while recording; nil over a whole window or page.
    static func frame(at p: CGPoint) -> CGRect? {
        guard trusted else { return nil }
        AXUIElementSetMessagingTimeout(system, 0.1)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &hit) == .success, let el = hit,
              let role = string(el, kAXRoleAttribute), !["AXWindow", "AXWebArea", "AXScrollArea", "AXApplication"].contains(role)
        else { return nil }
        return frame(el)
    }

    private static func read(_ el: AXUIElement) -> (Element?, window: String?, url: String?) {
        var path: [String] = []
        var window: String?
        var url: String?
        var cur: AXUIElement? = parent(of: el)
        var depth = 0
        while let c = cur, depth < 12 {
            let role = string(c, kAXRoleAttribute) ?? "?"
            let name = string(c, kAXTitleAttribute) ?? string(c, kAXDescriptionAttribute) ?? string(c, kAXIdentifierAttribute)
            path.insert(name.map { "\(role) '\(clip($0, 60))'" } ?? role, at: 0)
            if role == kAXWindowRole, window == nil { window = string(c, kAXTitleAttribute) }
            if role == "AXWebArea", url == nil { url = urlString(c) }
            cur = parent(of: c)
            depth += 1
        }
        let e = Element(
            role: string(el, kAXRoleAttribute),
            subrole: string(el, kAXSubroleAttribute),
            title: string(el, kAXTitleAttribute).map { clip($0, 200) },
            label: string(el, kAXDescriptionAttribute).map { clip($0, 200) },
            value: string(el, kAXValueAttribute).map { clip($0, 400) },
            help: string(el, kAXHelpAttribute).map { clip($0, 200) },
            identifier: string(el, kAXIdentifierAttribute),
            frame: frame(el).map(Rect.init),
            path: path)
        return (e, window, url)
    }

    private static func parent(of e: AXUIElement) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success, let v else { return nil }
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let n = v as? NSNumber { return n.stringValue }
        if let u = v as? URL { return u.absoluteString }
        return nil
    }

    private static func urlString(_ e: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, "AXURL" as CFString, &v) == .success, let v else { return nil }
        return (v as? URL)?.absoluteString ?? (v as? String)
    }

    private static func frame(_ e: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > n ? String(one.prefix(n)) + "…" : one
    }
}
