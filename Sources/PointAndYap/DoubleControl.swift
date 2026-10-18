import AppKit

/// Two taps of Control alone within 0.4 s, anywhere (global monitors need Accessibility, which the app has).
@MainActor
final class DoubleControl {
    private var monitors: [Any] = []
    private var downAt: Date?
    private var lastTap: Date?
    private let fire: () -> Void
    private let escape: () -> Void

    init(fire: @escaping () -> Void, escape: @escaping () -> Void) {
        self.fire = fire
        self.escape = escape
        let flags: (NSEvent) -> Void = { [weak self] e in MainActor.assumeIsolated { self?.flags(e) } }
        let other: (NSEvent) -> Void = { [weak self] e in
            MainActor.assumeIsolated {
                self?.reset()
                if e.type == .keyDown, e.keyCode == 53 { self?.escape() }   // Esc
            }
        }
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: other) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { other($0); return $0 }) { monitors.append(m) }
    }

    private func reset() { downAt = nil; lastTap = nil }

    private func flags(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let now = Date()
        if mods == .control {
            downAt = now
        } else if mods.isEmpty, let d = downAt, now.timeIntervalSince(d) < 0.3 {
            downAt = nil
            if let last = lastTap, now.timeIntervalSince(last) < 0.4 {
                lastTap = nil
                fire()
            } else {
                lastTap = now
            }
        } else {
            reset()
        }
    }
}
